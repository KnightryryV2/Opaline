import AVFoundation

// MARK: - SampleBufferEngine + Feed

/// Segment fetching/parsing/enqueuing for `SampleBufferEngine`: a pull-based
/// pipeline driven by `AVSampleBufferDisplayLayer`/`AVSampleBufferAudioRenderer`
/// asking for more data (`requestMediaDataWhenReady`), backed by a
/// `TrackProducer` per track that prefetches ahead of the synchronizer's
/// clock. See `TrackProducer.swift` for the per-track state.
extension SampleBufferEngine {
    /// How far ahead of playback each track tries to keep its decoded FIFO,
    /// in seconds. `PlaybackBufferPolicy.defaultForwardBufferDuration` (20s)
    /// is `AVPlayer`'s figure for buffering *compressed* network data;
    /// software-decoding AV1 keeps decoded `CMSampleBuffer`s in memory
    /// instead, so this engine targets a shorter, cheaper lead — enough to
    /// absorb ordinary network jitter without holding minutes of decoded
    /// frames around.
    static let targetAheadSeconds: Double = 10

    /// Starts the fetch/drain pipeline. Idempotent: only the first call (per
    /// engine instance) does anything, so `applyRate` can call this
    /// unconditionally every time the rate goes positive.
    func startFeeding() {
        feedQueue.async { [weak self] in
            self?.beginFeedingOnQueue()
        }
    }

    // MARK: - Setup

    private func beginFeedingOnQueue() {
        guard !isFeeding else {
            return
        }
        isFeeding = true
        videoProducer = videoProducer ?? makeProducer(kind: .video, track: videoTrack)
        audioProducer = audioProducer ?? makeProducer(kind: .audio, track: audioTrack)
        displayLayer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            self?.drainVideo()
        }
        audioRenderer.requestMediaDataWhenReady(on: feedQueue) { [weak self] in
            self?.drainAudio()
        }
        // Kick both tracks now: a renderer won't necessarily re-fire its
        // requestMediaDataWhenReady callback after the first (empty-FIFO)
        // invocation, and only a drain call starts a producer prefetching.
        // The synchronizer slaves its clock to the audio renderer, so an
        // unkicked audio track leaves the clock parked and the video frozen.
        resumeFeeding()
    }

    private func makeProducer(kind: TrackProducer.Kind, track: SampleBufferTrack) -> TrackProducer {
        TrackProducer(kind: kind, track: track, fetcher: fetcher, feedQueue: feedQueue)
    }

    /// Re-enters the drain/prefetch loop for both tracks. Used by
    /// `SampleBufferEngine+Seek.swift` after a seek's flush + producer reset:
    /// the `requestMediaDataWhenReady` callbacks stay registered for the
    /// engine's lifetime (see `startFeeding()`'s idempotency guard above), so
    /// this doesn't re-register them — it just kicks the same drain path they
    /// call, since a flushed renderer won't ask again on its own until it's
    /// given something to render. Call only on `feedQueue`.
    func resumeFeeding() {
        drainVideo()
        drainAudio()
    }

    // MARK: - Draining into renderers

    /// Pulls buffered video samples into `displayLayer`, updates whether the
    /// video track is starving, then tops up its prefetch. Runs on
    /// `feedQueue` (it's the `requestMediaDataWhenReady` callback).
    private func drainVideo() {
        guard let producer = videoProducer else {
            return
        }
        var enqueuedAny = false
        let starving = drain(
            producer: producer,
            enqueue: { [weak self] buffer in
                self?.displayLayer.enqueue(buffer)
                enqueuedAny = true
            },
            isReady: { [weak self] in self?.displayLayer.isReadyForMoreMediaData ?? false }
        )
        if enqueuedAny, !videoEnqueuedAny {
            videoEnqueuedAny = true
            AppLog.player("SB first video frame enqueued")
        }
        setVideoStarving(starving)
        topUp(producer)
        // Preroll off the reliable drain path (not just segment-append), so a
        // slow device can't leave the clock parked on the first frame.
        startClockIfPrerolled()
    }

    /// See `drainVideo()`; same shape for `audioRenderer`.
    private func drainAudio() {
        guard let producer = audioProducer else {
            return
        }
        var enqueuedAny = false
        let starving = drain(
            producer: producer,
            enqueue: { [weak self] buffer in
                self?.audioRenderer.enqueue(buffer)
                enqueuedAny = true
            },
            isReady: { [weak self] in self?.audioRenderer.isReadyForMoreMediaData ?? false }
        )
        if enqueuedAny, !audioEnqueuedAny {
            audioEnqueuedAny = true
            let err = audioRenderer.error.map { "\($0)" } ?? "none"
            AppLog.player("SB first audio frame enqueued, error=\(err)")
        }
        setAudioStarving(starving)
        topUp(producer)
    }

    /// Pulls samples out of `producer`'s FIFO into the renderer while it
    /// reports room. Returns whether that track is starving: the FIFO ran
    /// dry while the renderer still wanted more, and more data is still
    /// coming (not simply end-of-stream).
    private func drain(
        producer: TrackProducer,
        enqueue: (CMSampleBuffer) -> Void,
        isReady: () -> Bool
    ) -> Bool {
        while isReady() {
            guard let buffer = producer.dequeue() else {
                return !producer.isAtEnd
            }
            enqueue(buffer)
        }
        return false
    }

    // MARK: - Prefetch top-up

    /// Asks `producer` to fetch ahead of the current clock; whenever a
    /// segment lands, re-drains that track (a renderer that was starved a
    /// moment ago may now have somewhere to put the new samples) and
    /// refreshes the seek bar's buffered range.
    private func topUp(_ producer: TrackProducer) {
        producer.fillAhead(
            currentTimeProvider: { [weak self] in self?.synchronizer.currentTime().seconds ?? 0 },
            targetAhead: Self.targetAheadSeconds,
            onAppend: { [weak self] in self?.handleSegmentAppended(producer) },
            completion: {}
        )
    }

    private func handleSegmentAppended(_ producer: TrackProducer) {
        refreshBufferedRanges()
        switch producer.kind {
        case .video:
            drainVideo()
        case .audio:
            drainAudio()
        }
        // A newly landed segment may have crossed the preroll lead — start the
        // clock now if both tracks are ready and playback is wanted.
        startClockIfPrerolled()
    }

    /// `bufferedRanges` is a single range from the start to how far the
    /// video track (the seek bar's reference track) has decoded — this
    /// engine never evicts already-fetched data, so "buffered" is always a
    /// contiguous `[0, frontier]`.
    private func refreshBufferedRanges() {
        guard let videoProducer else {
            return
        }
        // frontierSeconds is read here on feedQueue; the assignment hops to
        // main because loadedTimeRanges is read there (periodic time observer).
        let end = CMTime(seconds: videoProducer.frontierSeconds, preferredTimescale: 600)
        DispatchQueue.main.async { [weak self] in
            self?.bufferedRanges = [CMTimeRange(start: .zero, end: end)]
        }
    }

    // MARK: - Starvation → state

    private func setVideoStarving(_ starving: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyVideoStarving(starving)
        }
    }

    private func setAudioStarving(_ starving: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyAudioStarving(starving)
        }
    }

    private func applyVideoStarving(_ starving: Bool) {
        guard videoStarving != starving else {
            return
        }
        videoStarving = starving
        updateState()
    }

    private func applyAudioStarving(_ starving: Bool) {
        guard audioStarving != starving else {
            return
        }
        audioStarving = starving
        updateState()
    }
}
