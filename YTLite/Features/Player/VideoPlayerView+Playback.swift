import AVFoundation
import AVKit
import UIKit

/// State for the stall-recovery clock resync (issue #14).
final class ClockResyncState {
    var isStalled = false
    var workItem: DispatchWorkItem?
    var lastResync: CFTimeInterval = 0
}

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
        engine?.onStateChange = nil
        engine?.onDurationResolved = nil
        clockResync.isStalled = false
        clockResync.workItem?.cancel()
        clockResync.workItem = nil
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
            "sponsorblock.skip".localized(with: categoryName),
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
        engine.onStateChange = { [weak self] state in
            self?.handleEngineStateChange(state)
        }
        engine.onDurationResolved = { [weak self] secs in
            self?.duration = secs
            self?.durationLabel.text = formatTime(secs)
            self?.refreshSponsorSeekBar()
        }
    }

    private func handleEngineStateChange(
        _ state: PlayerEngineState
    ) {
        switch state {
        case .waiting:
            spinner.startAnimating()
            setCenter(hidden: true)
            if (engine?.currentTime.seconds ?? 0) > 1 {
                clockResync.isStalled = true
            }
        case .playing:
            spinner.stopAnimating()
            setCenter(hidden: false)
            if clockResync.isStalled {
                clockResync.isStalled = false
                scheduleClockResync()
            }
        case .paused:
            spinner.stopAnimating()
            setCenter(hidden: false)
            clockResync.isStalled = false
            clockResync.workItem?.cancel()
        }
    }

    // MARK: - Stall Clock Resync

    /// A frame-accurate seek to the current position snaps the
    /// player clock back to the rendered media. Only runs while
    /// subtitles are active — nothing else is precise enough to
    /// notice the drift, and the seek costs a brief hiccup.
    private func scheduleClockResync() {
        guard !subtitleCues.isEmpty else {
            return
        }
        clockResync.workItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performClockResync()
        }
        clockResync.workItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0,
            execute: work
        )
    }

    private func performClockResync() {
        guard let engine,
              engine.state == .playing else {
            return
        }
        let now = CACurrentMediaTime()
        guard now - clockResync.lastResync > 10 else {
            return
        }
        clockResync.lastResync = now
        let time = engine.currentTime
        AppLog.player(
            "clock resync after stall at "
                + String(
                    format: "%.1fs",
                    CMTimeGetSeconds(time)
                )
        )
        engine.seek(to: time)
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
