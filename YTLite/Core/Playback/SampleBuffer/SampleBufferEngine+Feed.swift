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

    /// Minimum buffered lead (`frontierSeconds` minus `anchorSeconds`, same
    /// figure `fillAhead`'s `targetAhead` uses) before `startClockIfPrerolled()`
    /// restarts the synchronizer. Far smaller than `targetAheadSeconds` (a
    /// prefetch target, not a play-from minimum) — only needs to survive to
    /// the next drain cycle. A7 (iPad mini 2): 11-20ms/frame decode at 720p,
    /// 70-110ms fetches, so a fresh multi-second segment clears 1s with no
    /// added startup stall, while 1s is ~25-30x one frame at 30fps — the gap
    /// that was flapping the clock.
    static let minResumeLeadSeconds: Double = 1

    // starvationDebounceSeconds: SampleBufferEngine+Starvation.swift.

    /// How often `decodeStats` resamples — short enough to catch a stutter,
    /// long enough that one unusually fast/slow frame doesn't swing the
    /// number. Purely a stats cadence, unrelated to `targetAheadSeconds`.
    private static let statsWindowSeconds: Double = 1

    /// Max frames one `drainVideo()` pass decodes before yielding `feedQueue`
    /// back. Only the av01 path: dav1d decode is inline in `dequeue()`, on
    /// the same serial `feedQueue` audio drains on, so an uncapped loop can
    /// starve audio for hundreds of ms. Device-measured worst case at 2160p
    /// is 45-65 ms/frame; capping at 2 bounds one pass to ~130ms so audio
    /// still gets a turn several times a second.
    private static let maxAV1FramesPerDrain = 2

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

    /// Builds an av01 video producer's `Dav1dDecoder` up front: `Dav1dDecoder()`
    /// is failable (simulator, or a `dav1d_open` failure), and a track that
    /// can never decode should fail loudly via `failOnce` rather than sit
    /// silently starved forever.
    private func makeProducer(kind: TrackProducer.Kind, track: SampleBufferTrack) -> TrackProducer {
        guard kind == .video, track.isAV1 else {
            return TrackProducer(kind: kind, track: track, fetcher: fetcher, feedQueue: feedQueue)
        }
        guard let decoder = Dav1dDecoder() else {
            let producer = TrackProducer(
                kind: kind, track: track, fetcher: fetcher, feedQueue: feedQueue
            )
            producer.failOnce("dav1d decoder unavailable")
            return producer
        }
        return TrackProducer(
            kind: kind,
            track: track,
            fetcher: fetcher,
            feedQueue: feedQueue,
            decoder: decoder
        )
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
        // Only the still-decoding av01 path needs the cap — an avc1 producer
        // has no decoder and its FIFO holds already-compressed `.ready`
        // buffers, so draining it fully costs nanoseconds; see
        // `maxAV1FramesPerDrain`.
        let cap = producer.decoder != nil ? Self.maxAV1FramesPerDrain : Int.max
        let result = drain(
            producer: producer,
            cap: cap,
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
        // A yielded pass stopped only because it hit the cap, not because the
        // FIFO ran dry or the renderer's buffer is full — there's more
        // decodable data right now, so this is never starvation.
        setVideoStarving(result.starving)
        logStarvingEdge(kind: .video, wasStarving: videoStarvingFeed, isStarving: result.starving)
        videoStarvingFeed = result.starving
        updateClockForStarvation()
        topUp(producer)
        updateDecodeStats(producer)
        // Preroll off the reliable drain path (not just segment-append), so a
        // slow device can't leave the clock parked on the first frame.
        startClockIfPrerolled()
        if result.yielded {
            feedQueue.async { [weak self] in self?.drainVideo() }
        }
    }

    /// See `drainVideo()`; same shape for `audioRenderer`.
    private func drainAudio() {
        guard let producer = audioProducer else {
            return
        }
        var enqueuedAny = false
        let result = drain(
            producer: producer,
            cap: .max,
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
        setAudioStarving(result.starving)
        logStarvingEdge(kind: .audio, wasStarving: audioStarvingFeed, isStarving: result.starving)
        audioStarvingFeed = result.starving
        updateClockForStarvation()
        topUp(producer)
    }

    // logStarvingEdge lives in SampleBufferEngine+Starvation.swift, next to
    // the starving state it logs the transitions of.

    /// Pulls samples out of `producer`'s FIFO into the renderer while it
    /// reports room, stopping early once `cap` samples have been enqueued
    /// (`.max` for the audio/avc1 path, which never needs to yield — see
    /// `maxAV1FramesPerDrain`). `starving` is whether that track is
    /// starving: the FIFO ran dry while the renderer still wanted more, and
    /// more data is still coming (not simply end-of-stream) — never true
    /// just because the cap was hit. `yielded` is whether the cap stopped
    /// the loop while the renderer still wanted more, i.e. the caller should
    /// re-enter later to keep draining.
    private func drain(
        producer: TrackProducer,
        cap: Int,
        enqueue: (CMSampleBuffer) -> Void,
        isReady: () -> Bool
    ) -> (starving: Bool, yielded: Bool) {
        var decoded = 0
        while isReady() {
            if decoded >= cap {
                return (starving: false, yielded: true)
            }
            guard let buffer = producer.dequeue() else {
                return (starving: !producer.isAtEnd, yielded: false)
            }
            enqueue(buffer)
            decoded += 1
        }
        return (starving: false, yielded: false)
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

    // MARK: - Decode stats

    /// Diffs `producer`'s cumulative dav1d counters against the last sample
    /// to publish a rolling `decodeStats` snapshot. No-ops for a non-dav1d
    /// producer (avc1 track: `producer.decoder` is nil) and before a window
    /// has elapsed — called from `drainVideo()`, which runs far more often
    /// than once a second, so most calls just check the clock and return.
    private func updateDecodeStats(_ producer: TrackProducer) {
        guard producer.decoder != nil else {
            return
        }
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        guard elapsed >= Self.statsWindowSeconds else {
            return
        }
        let framesDelta = producer.framesDecoded - statsWindowFramesDecoded
        let decodeSecondsDelta = producer.decodeSecondsTotal - statsWindowDecodeSeconds
        let skippedDelta = producer.framesSkipped - statsWindowFramesSkipped
        let dimensions = producer.lastFrameDimensions
        let snapshot = DecodeStatsSnapshot(
            decodeFps: framesDelta > 0 ? Double(framesDelta) / elapsed : 0,
            msPerFrame: framesDelta > 0 ? (decodeSecondsDelta / Double(framesDelta)) * 1_000 : 0,
            framesSkipped: max(0, skippedDelta),
            width: dimensions?.width ?? 0,
            height: dimensions?.height ?? 0
        )
        statsWindowStart = now
        statsWindowFramesDecoded = producer.framesDecoded
        statsWindowFramesSkipped = producer.framesSkipped
        statsWindowDecodeSeconds = producer.decodeSecondsTotal
        DispatchQueue.main.async { [weak self] in
            self?.decodeStats = snapshot
        }
    }

    // setVideoStarving/setAudioStarving live in
    // SampleBufferEngine+Starvation.swift (kept out to stay under the
    // file-length limit).
}
