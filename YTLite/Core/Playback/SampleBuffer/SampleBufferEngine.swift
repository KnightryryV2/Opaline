import AVFoundation

// MARK: - SampleBufferTrack

/// One track's stream: where to fetch bytes and how to index them.
struct SampleBufferTrack {
    let url: URL
    let headers: [String: String]
    let index: MediaSegmentIndex
}

// MARK: - SampleBufferEngine

/// `PlayerEngine` backed by `AVSampleBufferDisplayLayer` +
/// `AVSampleBufferAudioRenderer`, kept in lockstep by an
/// `AVSampleBufferRenderSynchronizer` — the software-decoded AV1 path.
///
/// This is the transport-clock skeleton: segment fetching/parsing/enqueuing
/// lives in `SampleBufferEngine+Feed.swift` (+ `TrackProducer.swift`) and
/// precise seeking lands in `SampleBufferEngine+Seek.swift` (a later task),
/// which is why several stored properties below are internal rather than
/// private — those same-module extensions need them.
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

    /// Owns fetch/parse/decode state for the video track; created by
    /// `startFeeding()` in `SampleBufferEngine+Feed.swift`.
    var videoProducer: TrackProducer?
    /// Owns fetch/parse/decode state for the audio track; ditto.
    var audioProducer: TrackProducer?
    /// Guards `startFeeding()` so a second positive-rate call is a no-op.
    var isFeeding = false
    /// True until the feeder proves that track's FIFO has enough of a lead
    /// on playback; both default `true` so a `play()` issued before any
    /// data has been fetched reads as `.waiting`, not `.playing`. Mutated
    /// only on the main queue (see `SampleBufferEngine+Feed.swift`).
    var videoStarving = true
    /// See `videoStarving`.
    var audioStarving = true

    var onRateChange: (() -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?
    var onDurationResolved: ((Double) -> Void)?

    /// PTS the clock is anchored to (0 at first play; the seek target after a
    /// seek). The synchronizer starts here, matching the buffered samples'
    /// timestamps. Set by `SampleBufferEngine+Seek.swift`.
    var anchorSeconds: Double = 0
    /// Whether the synchronizer clock has been started (prerolled). Written
    /// only on `feedQueue` (`startClockIfPrerolled`, `performSeek`).
    var clockRunning = false

    private let durationSeconds: Double
    /// The last non-zero rate requested; `play()` resumes at this speed.
    private var storedRate: Float = 1
    /// The rate the caller wants (0 = paused). The synchronizer may still read
    /// 0 while prerolling — `rate` reports intent (like `AVPlayer.rate`), so a
    /// buffering start still shows as "playing, waiting".
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

    /// `.waiting` while prerolling or when either track's feeder hasn't decoded
    /// enough of a lead yet — see `clockRunning` / `videoStarving` /
    /// `audioStarving`. `.playing` only once the clock is actually running.
    var state: PlayerEngineState {
        guard desiredRate > 0 else {
            return .paused
        }
        return !clockRunning || videoStarving || audioStarving
            ? .waiting : .playing
    }

    var videoLayer: CALayer? { displayLayer }

    /// Set once the first video frame has been enqueued into `displayLayer`
    /// (see `SampleBufferEngine+Feed.swift`). That's the preroll signal: the
    /// display layer accepts frames even at rate 0, so gating on it can't
    /// deadlock, and starting the clock at `anchorSeconds` — the enqueued
    /// frames' timestamp — means audio (PTS ≥ anchor) is never treated as
    /// late. Reset on seek. Written only on `feedQueue`.
    var videoEnqueuedAny = false
    /// Same, for audio — diagnostics only (the clock is slaved to the audio
    /// renderer, so "did audio ever flow?" is the first thing to check).
    var audioEnqueuedAny = false

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
        notifyDurationResolved()
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
    /// `anchorSeconds` so the buffered samples aren't treated as late (which
    /// on slow devices dropped all audio and fast-forwarded video to "catch
    /// up"). Called by the feeder on `feedQueue` after each segment lands.
    func startClockIfPrerolled() {
        guard !clockRunning, desiredRate > 0, videoEnqueuedAny else {
            return
        }
        clockRunning = true
        synchronizer.setRate(
            desiredRate,
            time: CMTime(seconds: anchorSeconds, preferredTimescale: 600)
        )
        AppLog.player(
            "SB clock start at \(String(format: "%.1f", anchorSeconds))s"
                + " rate=\(desiredRate)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.onRateChange?()
            self?.updateState()
        }
    }

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

    /// Fires `onDurationResolved` once, asynchronously, so the caller can
    /// bind engine callbacks first. `VideoPlayerView.attach` binds them
    /// synchronously right after construction — before the next run-loop
    /// tick, when this actually fires.
    private func notifyDurationResolved() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.onDurationResolved?(self.durationSeconds)
        }
    }
}
