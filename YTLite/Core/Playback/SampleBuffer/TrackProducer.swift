import CoreMedia
import Foundation

// MARK: - TrackProducer

/// Owns one track's fetch → parse → decode pipeline: a lazily-fetched
/// format description, a `nextSegmentIndex` cursor into `track.index`, and
/// an in-memory FIFO of samples not yet handed to a renderer — `.ready`
/// (compressed, avc1/audio) or `.av01` (still-compressed OBU bytes; dav1d
/// decodes them lazily in `dequeue()` so the FIFO never holds more than a
/// few decoded frames — see `PendingSample`). All mutation happens on
/// `feedQueue`, the same serial queue `SampleBufferEngine+Feed.swift` drains
/// from. Owned by `SampleBufferEngine` via its `videoProducer`/
/// `audioProducer` properties.
///
/// A permanent fetch/parse failure sets `didFail`, which folds into
/// `isAtEnd` — the feeder stops prefetching that track. `SegmentFetcher`
/// itself retries a stalled/failed segment a few times with backoff before
/// that happens, so `didFail` means genuinely exhausted, not a network blip.
final class TrackProducer {
    // MARK: - Subtypes

    enum Kind {
        case video
        case audio
    }

    /// One FIFO entry. Compressed bytes stay buffered ahead of playback like
    /// the avc1 path (`Data` is COW, so `.av01` just retains a reference to
    /// the segment); only `dequeue()` turns an `.av01` entry into pixel data,
    /// a handful of frames ahead of the renderer — eager decode would buffer
    /// ~10s of raw pixel buffers (900 MB+ at 1080p), which this type avoids.
    enum PendingSample {
        case ready(CMSampleBuffer)
        case av01(Av01Pending)
    }

    /// The `.av01` payload of `PendingSample`, broken out into its own type
    /// because SwiftLint caps associated-value counts per enum case at 2.
    struct Av01Pending {
        let segment: Data
        let sample: FMP4Sample
        let decodeTicks: Int64
    }

    // MARK: - Type properties

    /// Consecutive `.av01` decode misses `decodeAv01` tolerates before
    /// calling `failOnce` instead of leaving `dequeue()` to loop forever.
    /// `max_frame_delay = 1` (`Dav1dShim.c`) means dav1d has no frame-level
    /// lookahead, so real warm-up is at most a couple of calls; 30 (a full
    /// second at 30fps) is ~10x that margin. Internal, not `private` —
    /// `private` doesn't cross files and `decodeAv01` lives in
    /// `TrackProducer+Fetch.swift`.
    static let maxConsecutiveDecodeMisses = 30

    // MARK: - Instance properties

    let kind: Kind
    let track: SampleBufferTrack

    // Members below are internal (not private) so the fetch/parse chain in
    // TrackProducer+Fetch.swift can reach them — Swift `private` doesn't cross
    // files. All are mutated only on `feedQueue`, keeping them serialized.
    let fetcher: SegmentFetcher
    let feedQueue: DispatchQueue
    let cancellationToken = CancellationToken()
    /// Non-nil only for an av01 video producer (see `SampleBufferEngine+Feed`
    /// `makeProducer`). `dequeue()` is documented feedQueue-only, and so is
    /// every other call site here, which satisfies `Dav1dDecoder`'s
    /// single-serial-queue requirement.
    let decoder: Dav1dDecoder?

    /// `avc1`/audio format description, parsed from the init segment. Stays
    /// `nil` for an av01 video track — dav1d needs no `stsd`/`avcC` parsing;
    /// its format description is derived per-sample from the decoded pixel
    /// buffer in `Av01SampleBufferFactory`. See `didParseInit` for whether
    /// the init segment has been fetched at all.
    var format: CMFormatDescription?
    /// True once the init segment has been fetched and (for non-av01 tracks)
    /// its format description parsed. Replaces a `format != nil` gate so an
    /// av01 track — which never gets a `format` — doesn't refetch the init
    /// segment forever. See `fillStep`.
    var didParseInit = false
    var frontierSeconds: Double = 0

    var timescale: CMTimeScale = 600
    var nextSegmentIndex = 0
    var fifo: [PendingSample] = []
    var didFail = false
    var hasLoggedFailure = false
    /// Guards the one-shot "reached end of stream" log — see `logEOFIfNeeded`.
    var hasLoggedEOF = false

    // MARK: - Decode stats (feedQueue-only)

    /// Cumulative dav1d frames/skips/decode-time for this producer's
    /// lifetime, touched only by `decodeAv01` (`TrackProducer+Fetch.swift`).
    /// Internal, not `private(set)`: `private` doesn't cross files.
    /// `SampleBufferEngine` samples these on a rolling window for decode
    /// fps/ms-per-frame; see `updateDecodeStats()` in `+Feed.swift`.
    var framesDecoded = 0
    /// `Av01SampleBufferFactory.makeSampleBuffer` calls that returned nil —
    /// dav1d still buffering, a stream error, or an unsupported chroma
    /// layout. Cumulative, same as `framesDecoded`.
    var framesSkipped = 0
    /// Wall-clock time spent inside `Av01SampleBufferFactory.makeSampleBuffer`
    /// (the dav1d decode call + pixel-buffer/`CMSampleBuffer` wrapping),
    /// summed — measured with `CACurrentMediaTime()` around that call only,
    /// so fetch/network/FIFO wait time is excluded.
    var decodeSecondsTotal: Double = 0
    /// Pixel dimensions of the most recently decoded frame, if any.
    var lastFrameDimensions: CMVideoDimensions?
    /// True while a prefetch chain is mid-flight. Overlapping `fillAhead`
    /// calls (a renderer re-asking before the current fetch lands) coalesce
    /// onto that one chain instead of double-fetching the same segment.
    private var isFilling = false
    /// Bumped by `reset(toSegmentIndex:)`. A fetch captures this value when
    /// issued; `handleInitSegment`/`handleMediaSegment` compare it against
    /// the current value and no-op if a seek moved on in the meantime. See
    /// `reset(toSegmentIndex:)`.
    var generation = 0

    /// Whether prefetching should stop: either every segment has been
    /// fetched, or a fetch/parse permanently failed.
    var isAtEnd: Bool { didFail || nextSegmentIndex >= track.index.segmentCount }

    // MARK: - Initializers

    init(
        kind: Kind,
        track: SampleBufferTrack,
        fetcher: SegmentFetcher,
        feedQueue: DispatchQueue,
        decoder: Dav1dDecoder? = nil
    ) {
        self.kind = kind
        self.track = track
        self.fetcher = fetcher
        self.feedQueue = feedQueue
        self.decoder = decoder
    }

    // MARK: - Instance methods

    /// Removes and returns the oldest not-yet-enqueued sample, decoding it
    /// first if it's a still-compressed `.av01` entry (see `decodeAv01` in
    /// `TrackProducer+Fetch.swift`). A miss (no picture produced) skips that
    /// entry and moves to the next — `nil` means "FIFO empty", never "this
    /// sample failed". Past `maxConsecutiveDecodeMisses` in a row,
    /// `decodeAv01` calls `failOnce` and this stops instead of grinding
    /// through the rest of the FIFO (the class doc comment's live-lock
    /// note). Call only on `feedQueue` (see `decoder`).
    func dequeue() -> CMSampleBuffer? {
        var consecutiveMisses = 0
        while !fifo.isEmpty {
            switch fifo.removeFirst() {
            case .ready(let buffer):
                return buffer
            case .av01(let pending):
                if let buffer = decodeAv01(pending, consecutiveMisses: &consecutiveMisses) {
                    return buffer
                }
                if didFail {
                    return nil
                }
            }
        }
        return nil
    }

    /// Fetches segments — the init segment first, on the very first call —
    /// until `frontierSeconds` is `targetAhead` seconds past whatever
    /// `currentTimeProvider()` reports, EOF is reached, or a fetch fails.
    /// `onAppend` fires after each segment lands (so the caller can drain
    /// newly available samples into its renderer without waiting for the
    /// next `requestMediaDataWhenReady` callback); `completion` fires once
    /// when the chain stops, for any reason. Call only on `feedQueue`.
    func fillAhead(
        currentTimeProvider: @escaping () -> Double,
        targetAhead: Double,
        onAppend: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        guard !isFilling else {
            completion()
            return
        }
        isFilling = true
        fillStep(
            currentTimeProvider: currentTimeProvider,
            targetAhead: targetAhead,
            onAppend: onAppend,
            completion: completion
        )
    }

    /// Discards the FIFO and any fetch in flight, then repositions the
    /// prefetch cursor at `index`'s start. Called by
    /// `SampleBufferEngine+Seek.swift` after flushing the renderers. Keeps
    /// `format`/`timescale`/`didParseInit` — the already-parsed init segment
    /// describes the same stream no matter where playback jumps to, so it
    /// isn't re-fetched. Also flushes `decoder`, if any: dropping the FIFO's
    /// `.av01` entries discards the *undecoded* samples, but dav1d's own
    /// internal picture queue/reference frames need an explicit flush too,
    /// or the next `decode(_:)` can hand back a picture from the pre-seek
    /// position (see `Dav1dDecoder.flush()`).
    ///
    /// Bumps `generation`, invalidating any fetch issued before this call:
    /// `handleInitSegment`/`handleMediaSegment` capture the generation at
    /// fetch-issue time and no-op if it no longer matches by the time their
    /// completion reaches `feedQueue`. That's what lets a seek interrupt an
    /// in-flight fetch without cancelling `cancellationToken` (which stays
    /// alive for post-seek fetches; only `deinit` cancels it).
    ///
    /// Also clears a stale `didFail`: a fetch/parse failure at the old
    /// position shouldn't permanently block prefetching from the new one.
    /// Call only on `feedQueue`.
    func reset(toSegmentIndex index: Int) {
        generation += 1
        fifo.removeAll()
        decoder?.flush()
        nextSegmentIndex = index
        frontierSeconds = track.index.startTime(at: index)
        isFilling = false
        didFail = false
        hasLoggedFailure = false
        hasLoggedEOF = false
    }

    // MARK: - Private

    /// One step of the prefetch chain begun by `fillAhead`. Guardless — only
    /// `fillAhead` (which flips `isFilling`) may enter; the chain then
    /// recurses here so re-entrant `fillAhead` calls no-op onto it. Clears
    /// `isFilling` when the chain stops (target reached, EOF, or failure).
    private func fillStep(
        currentTimeProvider: @escaping () -> Double,
        targetAhead: Double,
        onAppend: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        guard !isAtEnd, frontierSeconds - currentTimeProvider() < targetAhead else {
            logEOFIfNeeded()
            isFilling = false
            completion()
            return
        }
        guard didParseInit else {
            fetchInitSegment { [weak self] in
                self?.fillStep(
                    currentTimeProvider: currentTimeProvider,
                    targetAhead: targetAhead,
                    onAppend: onAppend,
                    completion: completion
                )
            }
            return
        }
        fetchAndContinue(
            format: format,
            currentTimeProvider: currentTimeProvider,
            targetAhead: targetAhead,
            onAppend: onAppend,
            completion: completion
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func fetchAndContinue(
        format: CMFormatDescription?,
        currentTimeProvider: @escaping () -> Double,
        targetAhead: Double,
        onAppend: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        fetchNextMediaSegment(format: format) { [weak self] appended in
            guard let self else {
                completion()
                return
            }
            if appended {
                onAppend()
            }
            self.fillStep(
                currentTimeProvider: currentTimeProvider,
                targetAhead: targetAhead,
                onAppend: onAppend,
                completion: completion
            )
        }
    }

    // MARK: - Deinitializers

    deinit {
        cancellationToken.cancel()
    }
}
