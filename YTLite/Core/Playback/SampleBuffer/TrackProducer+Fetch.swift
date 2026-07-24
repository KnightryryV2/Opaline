import CoreMedia
import Foundation

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
    func handleInitSegment(
        _ data: Data?,
        generation capturedGeneration: Int,
        completion: @escaping () -> Void
    ) {
        guard capturedGeneration == generation else {
            return
        }
        guard
            let data,
            let scale = FMP4FormatDescription.trackTimescale(initSegment: data),
            let format = parseFormat(initSegment: data)
        else {
            failOnce("init segment fetch/parse failed")
            completion()
            return
        }
        self.format = format
        timescale = scale
        completion()
    }

    func fetchNextMediaSegment(
        format: CMFormatDescription,
        completion: @escaping (Bool) -> Void
    ) {
        let index = nextSegmentIndex
        let capturedGeneration = generation
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
    func handleMediaSegment(
        _ data: Data?,
        index: Int,
        format: CMFormatDescription,
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
        let buffers = SampleBufferFactory.make(
            segment: data,
            samples: samples,
            format: format,
            segmentStart: track.index.startTime(at: index),
            timescale: timescale
        )
        fifo.append(contentsOf: buffers)
        frontierSeconds = track.index.startTime(at: index) + track.index.duration(at: index)
        nextSegmentIndex = index + 1
        completion(true)
    }
    // swiftlint:enable function_parameter_count

    private func parseFormat(initSegment: Data) -> CMFormatDescription? {
        switch kind {
        case .video:
            return FMP4FormatDescription.video(initSegment: initSegment)
        case .audio:
            return FMP4FormatDescription.audio(initSegment: initSegment)
        }
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
