import CoreMedia
import Foundation

// MARK: - TrackProducer

/// Owns one track's fetch → parse → decode pipeline: a lazily-fetched
/// format description, a `nextSegmentIndex` cursor into `track.index`, and
/// an in-memory FIFO of decoded `CMSampleBuffer`s not yet handed to a
/// renderer. All mutation happens on `feedQueue`, the same serial queue
/// `SampleBufferEngine+Feed.swift` drains from. Owned by `SampleBufferEngine`
/// via its `videoProducer`/`audioProducer` properties.
///
/// A permanent fetch/parse failure sets `didFail`, which folds into
/// `isAtEnd` — the feeder stops prefetching that track rather than
/// retrying forever. There's no retry-with-backoff in this v1; a
/// mid-playback network blip on one segment stalls that track for the
/// rest of playback (`onStateChange` reports `.waiting` and stays there).
final class TrackProducer {
    // MARK: - Subtypes

    enum Kind {
        case video
        case audio
    }

    // MARK: - Instance properties

    let kind: Kind
    let track: SampleBufferTrack

    // Members below are internal (not private) so the fetch/parse chain in
    // TrackProducer+Fetch.swift can reach them — Swift `private` doesn't cross
    // files. All are mutated only on `feedQueue`, keeping them serialized.
    let fetcher: SegmentFetcher
    let feedQueue: DispatchQueue
    let cancellationToken = CancellationToken()

    var format: CMFormatDescription?
    var frontierSeconds: Double = 0

    var timescale: CMTimeScale = 600
    var nextSegmentIndex = 0
    var fifo: [CMSampleBuffer] = []
    var didFail = false
    var hasLoggedFailure = false
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

    init(kind: Kind, track: SampleBufferTrack, fetcher: SegmentFetcher, feedQueue: DispatchQueue) {
        self.kind = kind
        self.track = track
        self.fetcher = fetcher
        self.feedQueue = feedQueue
    }

    // MARK: - Instance methods

    /// Removes and returns the oldest not-yet-enqueued sample, if any.
    /// Call only on `feedQueue`.
    func dequeue() -> CMSampleBuffer? {
        fifo.isEmpty ? nil : fifo.removeFirst()
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
    /// `format`/`timescale` — the already-parsed init segment describes the
    /// same stream no matter where playback jumps to, so it isn't re-fetched.
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
        nextSegmentIndex = index
        frontierSeconds = track.index.startTime(at: index)
        isFilling = false
        didFail = false
        hasLoggedFailure = false
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
            isFilling = false
            completion()
            return
        }
        guard let format else {
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
        format: CMFormatDescription,
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
