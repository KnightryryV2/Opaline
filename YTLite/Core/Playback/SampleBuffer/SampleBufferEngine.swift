import AVFoundation

// MARK: - SampleBufferTrack

/// One track's stream: where to fetch bytes and how to index them.
struct SampleBufferTrack {
    let url: URL
    let headers: [String: String]
    let index: MediaSegmentIndex
    /// True for an av01 video track, which routes through `Dav1dDecoder`
    /// instead of being handed to `AVSampleBufferDisplayLayer` compressed.
    /// Always `false` for audio tracks.
    let isAV1: Bool
}

// MARK: - DecodeStatsSnapshot

/// Rolling dav1d decode-performance snapshot for the stats-for-nerds overlay
/// (`WatchViewController+Stats.swift`). Built and refreshed roughly once a
/// second from `TrackProducer`'s cumulative counters — see
/// `updateDecodeStats()` in `SampleBufferEngine+Feed.swift`. `nil` on the
/// engine until the av01 video producer has completed one full window.
struct DecodeStatsSnapshot {
    /// Frames dav1d produced per second of real elapsed time in this window
    /// — i.e. actual sustained throughput, including any time the FIFO
    /// spent idle. This is the "can this device keep up" number.
    let decodeFps: Double
    /// Average time inside the dav1d decode call itself in this window,
    /// milliseconds — excludes fetch/network/FIFO wait, so it's the raw
    /// per-frame decode cost regardless of how starved the pipeline was.
    let msPerFrame: Double
    /// Frames dav1d returned no picture for in this window (not cumulative).
    let framesSkipped: Int
    /// Decoded picture size, from the most recent frame in this window.
    let width: Int32
    let height: Int32
}

// MARK: - SampleBufferEngine

/// `PlayerEngine` backed by `AVSampleBufferDisplayLayer` +
/// `AVSampleBufferAudioRenderer`, kept in lockstep by an
/// `AVSampleBufferRenderSynchronizer` — the software-decoded AV1 path. The
/// transport-clock skeleton: fetching/parsing/enqueuing lives in
/// `+Feed.swift` (+ `TrackProducer.swift`), seeking in `+Seek.swift`,
/// starvation/clock-parking in `+Starvation.swift` — several stored
/// properties below are internal rather than private for those extensions.
final class SampleBufferEngine: PlayerEngine {
    // MARK: - Instance properties

    /// Fetches fMP4 byte ranges for both tracks; consumed by the feeder.
    let fetcher: SegmentFetcher
    /// The video stream: URL, headers, and its parsed `sidx` index.
    let videoTrack: SampleBufferTrack
    /// The audio stream: URL, headers, and its parsed `sidx` index.
    let audioTrack: SampleBufferTrack
    /// Serial queue the feeder parses/enqueues segments on.
    let feedQueue = DispatchQueue(label: "SampleBufferEngine.feed", qos: .userInitiated)
    /// Renders decoded video frames; also this engine's `videoLayer`.
    let displayLayer = AVSampleBufferDisplayLayer()
    /// Renders decoded audio.
    let audioRenderer = AVSampleBufferAudioRenderer()
    /// Keeps `displayLayer` and `audioRenderer` on one clock.
    let synchronizer = AVSampleBufferRenderSynchronizer()

    /// Buffered ranges for the seek bar's fill; maintained by the feeder.
    /// Empty until then.
    var bufferedRanges: [CMTimeRange] = []

    /// Rolling dav1d decode stats for the overlay; `nil` until the av01
    /// video producer completes its first sampling window (or forever on an
    /// avc1 track). Written on `feedQueue`, hopped to main; see `updateDecodeStats()`.
    var decodeStats: DecodeStatsSnapshot?
    /// feedQueue-only `updateDecodeStats()` rolling-window bookkeeping.
    var statsWindowStart: CFTimeInterval = CACurrentMediaTime()
    var statsWindowFramesDecoded = 0
    var statsWindowFramesSkipped = 0
    var statsWindowDecodeSeconds: Double = 0

    /// Owns fetch/parse/decode state for the video track; created by
    /// `startFeeding()` in `SampleBufferEngine+Feed.swift`.
    var videoProducer: TrackProducer?
    /// Owns fetch/parse/decode state for the audio track; ditto.
    var audioProducer: TrackProducer?
    /// Guards `startFeeding()` so a second positive-rate call is a no-op.
    var isFeeding = false
    /// True until the feeder proves that track's FIFO has enough of a lead
    /// on playback; both default `true` so a `play()` before any data has
    /// been fetched reads as `.waiting`. Mutated only on main.
    var videoStarving = true
    /// See `videoStarving`.
    var audioStarving = true

    /// feedQueue-only mirrors of `videoStarving`/`audioStarving`, used by
    /// `updateClockForStarvation()` so the clock decision never races the
    /// main-queue pair's async hop — set synchronously from `drainVideo()`/
    /// `drainAudio()`.
    var videoStarvingFeed = true
    /// See `videoStarvingFeed`.
    var audioStarvingFeed = true

    var onRateChange: (() -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?
    /// Unlike `AVPlayerEngine`, duration is known synchronously at init, so
    /// setting this fires it immediately (on main) — see `notifyDurationResolved`.
    var onDurationResolved: ((Double) -> Void)? {
        get { _onDurationResolved }
        set {
            _onDurationResolved = newValue
            if newValue != nil {
                notifyDurationResolved()
            }
        }
    }

    private var _onDurationResolved: ((Double) -> Void)?

    /// PTS the clock is anchored to (0 at first play; the seek target after
    /// a seek), matching the buffered samples' timestamps.
    var anchorSeconds: Double = 0
    /// Whether the synchronizer clock has been started (prerolled). Written
    /// only on `feedQueue` (`startClockIfPrerolled`, `performSeek`).
    var clockRunning = false

    /// Debounce timer for `updateClockForStarvation()`; `nil` when no park is
    /// pending. `feedQueue`-only; internal since `private` doesn't cross files.
    var pendingParkWorkItem: DispatchWorkItem?

    private let durationSeconds: Double
    /// The last non-zero rate requested; `play()` resumes at this speed.
    private var storedRate: Float = 1
    /// The rate the caller wants (0 = paused); reports intent like
    /// `AVPlayer.rate`, so a buffering start shows as "playing, waiting".
    private var desiredRate: Float = 0
    private var lastState: PlayerEngineState = .paused

    var rate: Float {
        get { desiredRate }
        set {
            if newValue > 0 {
                storedRate = newValue
            }
            setDesiredRate(newValue)
        }
    }

    var currentTime: CMTime { synchronizer.currentTime() }

    var duration: CMTime { CMTime(seconds: durationSeconds, preferredTimescale: 600) }

    var loadedTimeRanges: [CMTimeRange] { bufferedRanges }

    /// `.waiting` while prerolling or either track lacks a lead (see
    /// `clockRunning` / `videoStarving` / `audioStarving`); `.playing` only
    /// once the clock is actually running.
    var state: PlayerEngineState {
        guard desiredRate > 0 else {
            return .paused
        }
        return !clockRunning || videoStarving || audioStarving
            ? .waiting : .playing
    }

    var videoLayer: CALayer? { displayLayer }

    /// Set once the first video frame has been enqueued into `displayLayer`
    /// (see `+Feed.swift`) — the preroll signal: the display layer accepts
    /// frames even at rate 0, so gating on it can't deadlock. Reset on seek.
    /// Written only on `feedQueue`.
    var videoEnqueuedAny = false
    /// Same, for audio — diagnostics only ("did audio ever flow?").
    var audioEnqueuedAny = false

    /// Guards `teardown()` (`+Teardown.swift`) so a second call is a no-op.
    /// Only ever set on main; internal since `private` doesn't cross files.
    var didTeardown = false

    // MARK: - Initializers

    init(
        video: SampleBufferTrack,
        audio: SampleBufferTrack,
        durationSeconds: Double,
        fetcher: SegmentFetcher = SegmentFetcher()
    ) {
        self.videoTrack = video
        self.audioTrack = audio
        self.durationSeconds = durationSeconds
        self.fetcher = fetcher
        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
    }

    // MARK: - PlayerEngine

    func play() {
        rate = storedRate
    }

    func pause() {
        setDesiredRate(0)
    }

    func playImmediately(atRate rate: Float) {
        self.rate = rate
    }

    // teardown() lives in SampleBufferEngine+Teardown.swift: stops the
    // renderers/producers so a discarded engine's decode loop doesn't keep
    // running in the background.

    // seek(to:toleranceBefore:toleranceAfter:completion:) lives in
    // SampleBufferEngine+Seek.swift: flushes both renderers and re-enqueues
    // from the containing segment's keyframe.

    func addPeriodicTimeObserver(
        interval: CMTime,
        queue: DispatchQueue,
        using block: @escaping (CMTime) -> Void
    ) -> Any {
        synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: queue, using: block)
    }

    func removeTimeObserver(_ token: Any) {
        synchronizer.removeTimeObserver(token)
    }

    // MARK: - State (shared with SampleBufferEngine+Feed.swift)

    /// Recomputes `state` and fires `onStateChange` only on a transition.
    /// Called from `applyRate` (already on main) and from
    /// `SampleBufferEngine+Feed.swift` whenever starvation flips (also
    /// marshaled to main there) — never call this off the main queue.
    func updateState() {
        let newState = state
        guard newState != lastState else {
            return
        }
        lastState = newState
        onStateChange?(newState)
    }

    /// Starts the synchronizer clock once prerolled — anchored to
    /// `anchorSeconds` so buffered samples aren't treated as late (which on
    /// slow devices dropped audio and fast-forwarded video to "catch up").
    /// The one restart path, shared by a fresh play()/seek() and a park
    /// recovery (`updateClockForStarvation()`).
    func startClockIfPrerolled() {
        guard !clockRunning, desiredRate > 0, videoEnqueuedAny,
            hasSufficientLead(videoProducer), hasSufficientLead(audioProducer) else {
            return
        }
        clockRunning = true
        synchronizer.setRate(
            desiredRate,
            time: CMTime(seconds: anchorSeconds, preferredTimescale: 600)
        )
        let anchor = String(format: "%.1f", anchorSeconds)
        AppLog.player("SB clock start at \(anchor)s rate=\(desiredRate)")
        DispatchQueue.main.async { [weak self] in
            self?.onRateChange?()
            self?.updateState()
        }
    }

    // hasSufficientLead lives in SampleBufferEngine+Starvation.swift, next to
    // the starvation state it gates the clock restart on.

    // MARK: - Private

    /// Records the intended rate and either starts/stops the running clock or
    /// leaves preroll to the feeder. On the first play the clock stays parked
    /// (rate 0) until `startClockIfPrerolled` fires; pause/resume after preroll
    /// toggles the synchronizer directly.
    private func setDesiredRate(_ newRate: Float) {
        desiredRate = newRate
        if newRate > 0 {
            startFeeding()
        }
        if newRate == 0 || clockRunning {
            synchronizer.setRate(newRate, time: .invalid)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onRateChange?()
            self?.updateState()
        }
    }

    /// Fires the just-assigned `onDurationResolved`, asynchronously (the
    /// protocol's documented contract is "fires on the main queue"; this
    /// keeps that true even if the callback is assigned off-main).
    private func notifyDurationResolved() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self._onDurationResolved?(self.durationSeconds)
        }
    }
}
