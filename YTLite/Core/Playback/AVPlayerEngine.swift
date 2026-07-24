import AVFoundation

// MARK: - AVPlayerEngine

/// `PlayerEngine` backed by `AVPlayer`. Owns the player and the KVO on
/// rate / time-control / item-duration, forwarding each change through the
/// engine callbacks. The renderer-facing `AVPlayerLayer` stays in
/// `VideoPlayerView`, which wires it to `player`.
final class AVPlayerEngine: PlayerEngine {
    /// The wrapped player. Exposed for renderer-bound concerns (layer, PiP,
    /// pinch-zoom, mini bar) that Phase 1 hasn't migrated off `AVPlayer` yet.
    let player: AVPlayer

    var onRateChange: (() -> Void)?
    var onStateChange: ((PlayerEngineState) -> Void)?
    var onDurationResolved: ((Double) -> Void)?

    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?

    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    var currentTime: CMTime { player.currentTime() }

    var duration: CMTime { player.currentItem?.duration ?? .indefinite }

    var loadedTimeRanges: [CMTimeRange] {
        // KVO exposes NSValue-boxed ranges.
        (player.currentItem?.loadedTimeRanges ?? [])
            .compactMap { $0 as? CMTimeRange }
    }

    var state: PlayerEngineState {
        Self.engineState(from: player.timeControlStatus)
    }

    init(item: AVPlayerItem) {
        player = AVPlayer(playerItem: item)
        observeDuration(of: item)
        observePlayer()
    }

    private static func engineState(
        from status: AVPlayer.TimeControlStatus
    ) -> PlayerEngineState {
        switch status {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        case .paused:
            return .paused
        @unknown default:
            return .paused
        }
    }

    // MARK: PlayerEngine

    func play() { player.play() }

    func pause() { player.pause() }

    func playImmediately(atRate rate: Float) {
        player.playImmediately(atRate: rate)
    }

    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completion: ((Bool) -> Void)?
    ) {
        if let completion {
            player.seek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completion
            )
        } else {
            player.seek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter
            )
        }
    }

    func addPeriodicTimeObserver(
        interval: CMTime,
        queue: DispatchQueue,
        using block: @escaping (CMTime) -> Void
    ) -> Any {
        player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: queue,
            using: block
        )
    }

    func removeTimeObserver(_ token: Any) {
        player.removeTimeObserver(token)
    }

    /// Swaps in a new item on the same player (background video-to-video
    /// reuse), rebinding the duration observer to the new item.
    func replace(item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
        observeDuration(of: item)
    }

    // MARK: KVO

    private func observePlayer() {
        rateObservation = player.observe(
            \.rate,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.onRateChange?() }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] observed, _ in
            let state = Self.engineState(from: observed.timeControlStatus)
            DispatchQueue.main.async { self?.onStateChange?(state) }
        }
    }

    private func observeDuration(of item: AVPlayerItem) {
        durationObservation = item.observe(
            \.duration,
            options: [.new]
        ) { [weak self] item, _ in
            let secs = CMTimeGetSeconds(item.duration)
            guard secs.isFinite, secs > 0 else {
                return
            }
            DispatchQueue.main.async { self?.onDurationResolved?(secs) }
        }
    }
}
