import AVKit
import UIKit

// MARK: - Picture in Picture

extension VideoPlayerView {
    /// Whether PiP is possible at all: device support + the user setting.
    var isPiPAvailable: Bool {
        let supported = AVPictureInPictureController
            .isPictureInPictureSupported()
        let enabled = UserDefaults.standard.object(
            forKey: UserDefaultsKeys.Player.pipEnabled
        ) as? Bool ?? true
        return supported && enabled
    }

    func setupPiP() {
        setControlAvailability(
            pipButton,
            available: isPiPAvailable
        )
        guard isPiPAvailable else {
            // Also drops a controller created before the user
            // disabled the setting — it would otherwise keep
            // serving the (reused) player layer.
            pipController = nil
            return
        }
        guard pipController == nil else {
            return
        }
        pipController = AVPictureInPictureController(
            playerLayer: playerLayer
        )
        pipController?.delegate = self
    }

    /// Auto-PiP on backgrounding is wanted only in fullscreen (with the
    /// setting on) — that case keeps its controller. Everywhere else only
    /// the controller is dropped here: that alone prevents auto-PiP at the
    /// transition, and keeping the layer attached means a Control Center /
    /// Notification Center peek (which fires resignActive but never
    /// didEnterBackground) doesn't touch the pipeline — no audio hiccup.
    @objc
    func appWillResignActive() {
        guard pipController?.isPictureInPictureActive != true else {
            return
        }
        wasPlayingOnResign = (player?.rate ?? 0) > 0
        if !isFullscreen {
            pipController = nil
        }
    }

    /// A real backgrounding: detach the layer (a layer-backed player is
    /// paused by iOS in the background) and, since without a controller the
    /// system may have paused playback during the transition, resume on the
    /// next tick — after every handler (incl. the mini bar's detach) ran.
    @objc
    func appDidEnterBackground() {
        guard pipController?.isPictureInPictureActive != true,
              BackgroundPlaybackService.isEnabled
        else {
            return
        }
        playerLayer.player = nil
        guard wasPlayingOnResign else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            if let player = self?.player, player.rate == 0 {
                player.play()
            }
        }
    }

    @objc
    func appDidBecomeActive() {
        if let engine, engine.videoLayer != nil {
            restoreSampleBufferVideo(engine)
            return
        }
        guard let player else {
            return
        }
        if playerLayer.player == nil {
            playerLayer.player = player
        }
        // Re-evaluate the PiP setting (it may have changed in Settings).
        setupPiP()
    }

    /// Sample-buffer path: audio survives backgrounding (the audio renderer
    /// keeps running under the audio session) but `AVSampleBufferDisplayLayer`
    /// stops rendering and comes back empty — sound with no picture. Nothing
    /// above re-enqueues it, because every other line here targets
    /// `AVPlayerLayer`, which this path doesn't use.
    ///
    /// Seeking to the current position is the cheap kick: it flushes the
    /// renderers and re-enqueues from the containing segment's keyframe
    /// through the engine's existing preroll, so a paused player also gets a
    /// visible frame back instead of black. Costs the usual segment-boundary
    /// snap (playback may rewind a few seconds); a frame-exact re-enqueue
    /// would need an engine-level "re-render at current time" that doesn't
    /// move the clock.
    private func restoreSampleBufferVideo(_ engine: PlayerEngine) {
        let now = engine.currentTime
        guard now.isNumeric else {
            return
        }
        engine.seek(to: now)
    }

    @objc
    func pipTapped() {
        guard let pip = pipController else {
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }
}

// MARK: - PiP Delegate

extension VideoPlayerView: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipButton.setImage(
            PlayerIcons.pipExit(),
            for: .normal
        )
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipButton.setImage(
            PlayerIcons.pip(),
            for: .normal
        )
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
