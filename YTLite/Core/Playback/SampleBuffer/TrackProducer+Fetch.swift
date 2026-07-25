import CoreMedia
import Foundation
import QuartzCore

// MARK: - TrackProducer + Fetch

/// The fetch → parse → decode half of `TrackProducer`: pulls the init segment
/// (for the format description) and successive media segments over
/// `SegmentFetcher`, turning each into `CMSampleBuffer`s appended to the FIFO.
/// Split out to keep `TrackProducer.swift` within the file/type-length limits;
/// the members it touches are internal for the same reason. Runs on
/// `feedQueue`.
extension TrackProducer {
    func fetchInitSegment(completion: @escaping () -> Void) {
        let capturedGeneration = generation
        AppLog.log("SampleBuffer", "\(kind) producer: fetching init segment")
        fetcher.fetch(
            url: track.url,
            headers: track.headers,
            range: track.index.initRange,
            cancellationToken: cancellationToken
        ) { [weak self] data in
            self?.feedQueue.async {
                self?.handleInitSegment(
                    data,
                    generation: capturedGeneration,
                    completion: completion
                )
            }
        }
    }

    /// No-ops if `generation` has moved on since this fetch was issued — a
    /// seek's `reset(toSegmentIndex:)` landed while it was in flight, so its
    /// result no longer belongs to the current cursor. See
    /// `reset(toSegmentIndex:)`.
    ///
    /// An av01 video track needs only the `mdhd` timescale from the init
    /// segment — `FMP4FormatDescription.video` parses `avc1`/`avcC` only and
    /// would (correctly) return nil for av01, so that parse is skipped
    /// rather than treated as a failure. Audio and avc1 video still hard-fail
    /// when their format won't parse: those paths need a real
    /// `CMFormatDescription` to hand samples to `AVSampleBufferDisplayLayer`/
    /// `AVSampleBufferAudioRenderer`.
    func handleInitSegment(
        _ data: Data?,
        generation capturedGeneration: Int,
        completion: @escaping () -> Void
    ) {
        guard capturedGeneration == generation else {
            return
        }
        guard let data, let scale = FMP4FormatDescription.trackTimescale(initSegment: data) else {
            failOnce("init segment fetch/parse failed")
            completion()
            return
        }
        if track.isAV1, kind == .video {
            timescale = scale
            didParseInit = true
            AppLog.log("SampleBuffer", "\(kind) producer: init parsed (av01, scale=\(scale))")
            completion()
            return
        }
        guard let format = parseFormat(initSegment: data) else {
            failOnce("init segment fetch/parse failed")
            completion()
            return
        }
        self.format = format
        timescale = scale
        didParseInit = true
        AppLog.log("SampleBuffer", "\(kind) producer: init segment parsed (scale=\(scale))")
        completion()
    }

    func fetchNextMediaSegment(
        format: CMFormatDescription?,
        completion: @escaping (Bool) -> Void
    ) {
        let index = nextSegmentIndex
        let capturedGeneration = generation
        AppLog.log("SampleBuffer", "\(kind) producer: fetching segment \(index)")
        fetcher.fetch(
            url: track.url,
            headers: track.headers,
            range: track.index.byteRange(at: index),
            cancellationToken: cancellationToken
        ) { [weak self] data in
            self?.feedQueue.async {
                self?.handleMediaSegment(
                    data,
                    index: index,
                    format: format,
                    generation: capturedGeneration,
                    completion: completion
                )
            }
        }
    }

    // swiftlint:disable function_parameter_count
    /// See the no-op note on `handleInitSegment` — same generation guard,
    /// same reason: a seek's `reset(toSegmentIndex:)` may have moved
    /// `nextSegmentIndex`/`frontierSeconds` on since this fetch started, and
    /// splicing a stale segment's samples into the FIFO the post-seek fetch
    /// is building would corrupt it.
    ///
    /// av01 appends `.av01` entries (still-compressed OBU bytes + planned
    /// timing) instead of decoding here — see `PendingSample`/`dequeue()`.
    func handleMediaSegment(
        _ data: Data?,
        index: Int,
        format: CMFormatDescription?,
        generation capturedGeneration: Int,
        completion: (Bool) -> Void
    ) {
        guard capturedGeneration == generation else {
            return
        }
        guard let data, let samples = FMP4SampleTable.parse(mediaSegment: data) else {
            failOnce("media segment \(index) fetch/parse failed")
            completion(false)
            return
        }
        guard appendSamples(samples, data: data, format: format, index: index) else {
            completion(false)
            return
        }
        frontierSeconds = track.index.startTime(at: index) + track.index.duration(at: index)
        nextSegmentIndex = index + 1
        let frontier = String(format: "%.1f", frontierSeconds)
        let msg = "\(kind) producer: segment \(index) appended, frontier=\(frontier)s"
        AppLog.log("SampleBuffer", msg)
        completion(true)
    }
    // swiftlint:enable function_parameter_count

    /// Appends `samples` to the FIFO as `.av01` (planned, undecoded) or
    /// `.ready` entries depending on the track's codec. Returns `false` (and
    /// calls `failOnce`) only for the avc1/audio case with no format —
    /// shouldn't happen once `didParseInit` gates this call, but guards
    /// against a future caller wiring things up wrong.
    private func appendSamples(
        _ samples: [FMP4Sample],
        data: Data,
        format: CMFormatDescription?,
        index: Int
    ) -> Bool {
        let segmentStart = track.index.startTime(at: index)
        if track.isAV1 {
            let planned = Av01SampleBufferFactory.planDecodeTicks(
                samples: samples,
                segmentStart: segmentStart,
                timescale: timescale
            )
            fifo.append(contentsOf: planned.map {
                .av01(TrackProducer.Av01Pending(
                    segment: data,
                    sample: $0.sample,
                    decodeTicks: $0.decodeTicks
                ))
            })
            return true
        }
        guard let format else {
            failOnce("media segment \(index) missing format")
            return false
        }
        let buffers = SampleBufferFactory.make(
            segment: data,
            samples: samples,
            format: format,
            segmentStart: segmentStart,
            timescale: timescale
        )
        fifo.append(contentsOf: buffers.map(TrackProducer.PendingSample.ready))
        return true
    }

    private func parseFormat(initSegment: Data) -> CMFormatDescription? {
        switch kind {
        case .video:
            return FMP4FormatDescription.video(initSegment: initSegment)
        case .audio:
            return FMP4FormatDescription.audio(initSegment: initSegment)
        }
    }

    /// The `.av01` half of `dequeue()`, split out to keep that function under
    /// the lint body-length limit. Decodes one pending sample via dav1d,
    /// updates decode stats, and — once `consecutiveMisses` reaches
    /// `maxConsecutiveDecodeMisses` — calls `failOnce` so the caller can stop
    /// (checked via `didFail`, since dav1d failing persistently would
    /// otherwise have `dequeue()`'s caller spin through the whole FIFO
    /// forever refetching more of the same broken stream).
    ///
    /// - Returns: The decoded buffer, or `nil` on a miss (`decoder` absent,
    ///   dav1d still buffering, or a decode error — `Dav1dDecoder.decode`
    ///   already logs which).
    func decodeAv01(
        _ pending: TrackProducer.Av01Pending,
        consecutiveMisses: inout Int
    ) -> CMSampleBuffer? {
        guard let decoder else {
            return nil
        }
        let decodeStart = CACurrentMediaTime()
        let buffer = Av01SampleBufferFactory.makeSampleBuffer(
            segment: pending.segment,
            sample: pending.sample,
            decoder: decoder,
            decodeTicks: pending.decodeTicks,
            timescale: timescale
        )
        decodeSecondsTotal += CACurrentMediaTime() - decodeStart
        guard let buffer else {
            framesSkipped += 1
            consecutiveMisses += 1
            if consecutiveMisses >= Self.maxConsecutiveDecodeMisses {
                failOnce("dav1d produced no picture \(consecutiveMisses) samples in a row")
            }
            return nil
        }
        framesDecoded += 1
        if let desc = CMSampleBufferGetFormatDescription(buffer) {
            lastFrameDimensions = CMVideoFormatDescriptionGetDimensions(desc)
        }
        return buffer
    }

    /// One-shot "reached end of stream" log for `fillStep`'s terminating
    /// guard — `didFail` already logs via `failOnce`, so this covers only the
    /// other half of `isAtEnd` (natural EOF), and only once: every `topUp()`
    /// call re-enters `fillStep` for the rest of playback, so without
    /// `hasLoggedEOF` this would log on every drain forever.
    func logEOFIfNeeded() {
        guard isAtEnd, !didFail, !hasLoggedEOF else {
            return
        }
        hasLoggedEOF = true
        let msg = "\(kind) producer: prefetch reached end at segment \(nextSegmentIndex)"
        AppLog.log("SampleBuffer", msg)
    }

    func failOnce(_ message: String) {
        didFail = true
        guard !hasLoggedFailure else {
            return
        }
        hasLoggedFailure = true
        AppLog.log("SampleBuffer", "\(kind) producer: \(message)")
    }
}
