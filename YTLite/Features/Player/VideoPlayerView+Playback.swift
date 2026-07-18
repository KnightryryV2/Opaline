import AVFoundation
import AVKit
import UIKit

// MARK: - Playback API

extension VideoPlayerView {
    func attach(engine newEngine: PlayerEngine) {
        engine = newEngine
        playerLayer.isHidden = false
        playerLayer.player = (newEngine as? AVPlayerEngine)?.player
        bindEngineCallbacks(newEngine)
        addPeriodicObserver()
        updatePlayPauseIcon()
        setupPiP()
        if playbackSpeed != 1.0 {
            newEngine.rate = playbackSpeed
        }
    }

    /// Rebinds after the host replaced the item on the SAME engine
    /// (background video-to-video transition): the duration callback watches
    /// the current item, so the engine re-attaches it and the view refreshes
    /// its callbacks. The layer is deliberately untouched — it stays detached
    /// while backgrounded and comes back on activation.
    func rebind(engine newEngine: PlayerEngine) {
        engine = newEngine
        bindEngineCallbacks(newEngine)
        duration = 0
    }

    func detach() {
        removePeriodicObserver()
        engine?.onRateChange = nil
        engine?.onWaitingChange = nil
        engine?.onDurationResolved = nil
        playerLayer.isHidden = false
        playerLayer.player = nil
        engine = nil
        hideSkipButton()
        sponsorSegments = []
        seekBar.setSegments([])
        speedOverlay.isHidden = true
    }

    func setSponsorSegments(
        _ segments: [SponsorBlockSegment]
    ) {
        sponsorSegments = segments
        refreshSponsorSeekBar()
    }

    func showSkipButton(categoryName: String) {
        skipButton.setTitle(
            "Skip \(categoryName)",
            for: .normal
        )
        skipButton.isHidden = false
    }

    func hideSkipButton() {
        skipButton.isHidden = true
    }

    func refreshSponsorSeekBar() {
        guard duration > 0 else {
            return
        }
        let normalized = sponsorSegments
            .filter {
                SponsorBlockService.skipBehavior(
                    for: $0.category
                ) != .disabled
            }
            .map {
                SeekBarSegment(
                    start: $0.startTime / duration,
                    end: $0.endTime / duration,
                    color: $0.category.seekBarColor
                )
            }
        seekBar.setSegments(normalized)
    }

    // MARK: - Periodic Observer

    func addPeriodicObserver() {
        guard let engine else {
            return
        }
        let interval = CMTime(
            seconds: 0.1,
            preferredTimescale: 600
        )
        timeObserver = engine.addPeriodicTimeObserver(
            interval: interval,
            queue: .main
        ) { [weak self] time in
            self?.updateProgress(time: time)
        }
    }

    func removePeriodicObserver() {
        if let obs = timeObserver {
            engine?.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    // MARK: - Engine Callbacks

    /// Wires the engine's rate / buffering / duration signals into the UI.
    /// The engine delivers these on the main queue.
    func bindEngineCallbacks(_ engine: PlayerEngine) {
        engine.onRateChange = { [weak self] in
            self?.updatePlayPauseIcon()
        }
        engine.onWaitingChange = { [weak self] waiting in
            if waiting {
                self?.spinner.startAnimating()
                self?.setCenter(hidden: true)
            } else {
                self?.spinner.stopAnimating()
                self?.setCenter(hidden: false)
            }
        }
        engine.onDurationResolved = { [weak self] secs in
            self?.duration = secs
            self?.durationLabel.text = formatTime(secs)
            self?.refreshSponsorSeekBar()
        }
    }

    // MARK: - Progress

    func updateProgress(time: CMTime) {
        guard duration > 0 else {
            return
        }
        let secs = CMTimeGetSeconds(time)
        currentTimeLabel.text = formatTime(secs)
        if !seekBar.isScrubbing {
            seekBar.setProgress(secs / duration)
        }
        updateBuffer(at: time)
        onTimeUpdate?(secs)
    }

    private func updateBuffer(at time: CMTime) {
        guard let engine else {
            return
        }
        let buffered = engine.loadedTimeRanges
            .filter {
                CMTimeRangeContainsTime($0, time: time)
            }
            .map {
                CMTimeGetSeconds($0.start)
                    + CMTimeGetSeconds($0.duration)
            }
            .max() ?? 0
        seekBar.setBuffer(buffered / duration)
    }
}
