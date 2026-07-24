import AVFoundation

// MARK: - PlayerEngine

/// Coarse transport state, mirroring `AVPlayer.timeControlStatus`: `waiting`
/// means playback wants to advance but is buffering (a stall, from the UI's
/// point of view).
enum PlayerEngineState {
    case playing
    case paused
    case waiting
}

/// The playback transport + clock the player shell drives, abstracted away from
/// `AVPlayer`. Phase 1 ships one implementation, `AVPlayerEngine`; a later phase
/// adds a sample-buffer engine for software-decoded AV1. The shell only ever
/// asks the engine to play/pause/seek/rate and reports its clock, so swapping
/// engines never ripples into the UI.
///
/// Renderer-bound concerns still tied to `AVPlayerLayer` (PiP, pinch-zoom, the
/// mini bar) reach the concrete `AVPlayer` through `VideoPlayerView.player` for
/// now; they migrate onto engine-level primitives in later phases.
protocol PlayerEngine: AnyObject {
    /// Playback rate; 0 = paused. Setting a positive rate resumes.
    var rate: Float { get set }
    /// Current playhead position.
    var currentTime: CMTime { get }
    /// Item duration once known, else `.indefinite`.
    var duration: CMTime { get }
    /// Buffered ranges, for the seek bar's buffer fill.
    var loadedTimeRanges: [CMTimeRange] { get }
    /// Current transport state (playing / paused / waiting-to-buffer).
    var state: PlayerEngineState { get }

    /// Fires (on the main queue) when the play/pause state changes — drives the
    /// play/pause icon.
    var onRateChange: (() -> Void)? { get set }
    /// Fires (on the main queue) whenever `state` changes — drives the
    /// buffering spinner and the stall-recovery clock resync.
    var onStateChange: ((PlayerEngineState) -> Void)? { get set }
    /// Fires (on the main queue) once the item duration resolves to a finite
    /// value.
    var onDurationResolved: ((Double) -> Void)? { get set }

    func play()
    func pause()
    /// Starts playback the moment frames are decodable, at `rate`.
    func playImmediately(atRate rate: Float)
    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completion: ((Bool) -> Void)?
    )

    /// Adds a periodic clock observer; returns an opaque token to hand back to
    /// `removeTimeObserver`.
    func addPeriodicTimeObserver(
        interval: CMTime,
        queue: DispatchQueue,
        using block: @escaping (CMTime) -> Void
    ) -> Any
    func removeTimeObserver(_ token: Any)
}

extension PlayerEngine {
    /// Whether playback is currently advancing.
    var isPlaying: Bool { rate > 0 }

    func seek(to time: CMTime) {
        seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completion: nil
        )
    }
}
