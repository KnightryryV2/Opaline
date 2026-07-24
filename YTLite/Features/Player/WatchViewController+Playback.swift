import AVFoundation
import AVKit
import UIKit

// MARK: - Playback

extension WatchViewController {
    func startPlayback() {
        playbackFacade.watchtimeTracker.timeProvider = { [weak self] in
            self?.videoPlayerView?.engine?.currentTime.seconds ?? 0
        }
        playbackFacade.start(
            videoId: initialVideo.id,
            apiClient: client,
            cancellationToken: pageLoadToken
        )
    }

    func attachPlayer(
        item: AVPlayerItem,
        minimizeStalling: Bool = true
    ) {
        guard !pageLoadToken.isCancelled else {
            return
        }
        if let saved = savedEngineForBackground {
            savedEngineForBackground = nil
            attachToExistingEngine(saved, item: item)
            return
        }
        resetPlaybackSurfaces()
        playerSpinner.stopAnimating()
        playerStatusLabel.isHidden = true
        PlaybackBufferPolicy.configure(item: item)
        startObservingPlayerItem(item)
        let engine = AVPlayerEngine(item: item)
        PlaybackBufferPolicy.configure(
            player: engine.player,
            waitsToMinimizeStalling: minimizeStalling
        )
        let pv = getOrCreatePlayerView()
        configureSponsorBlock(on: pv)
        playerContainer.bringSubviewToFront(pv)
        pv.attach(engine: engine)
        // Start as soon as the first frames are decodable instead of
        // waiting for the stall-minimizing buffer to fill.
        engine.playImmediately(atRate: pv.playbackSpeed)
    }

    /// Attaches a pre-built engine (the sample-buffer path) directly, skipping
    /// the `AVPlayerItem`-specific KVO (`startObservingPlayerItem` watches
    /// item status/notifications the engine doesn't have) and the buffer
    /// policy, which only applies to `AVPlayerItem`/`AVPlayer`.
    func attachEngine(_ engine: PlayerEngine) {
        guard !pageLoadToken.isCancelled else {
            return
        }
        resetPlaybackSurfaces()
        playerSpinner.stopAnimating()
        playerStatusLabel.isHidden = true
        let pv = getOrCreatePlayerView()
        configureSponsorBlock(on: pv)
        playerContainer.bringSubviewToFront(pv)
        pv.attach(engine: engine)
        engine.playImmediately(atRate: pv.playbackSpeed)
        // The engine path has no AVPlayerItem status observer, so start the
        // Now Playing session and saved-position resume here instead — the
        // engine's duration is known upfront from its ctor.
        let duration = engine.duration.seconds
        if duration.isFinite, duration > 0 {
            beginNowPlayingSession(duration: duration)
        }
        seekToSavedPositionIfNeeded()
    }

    private func attachToExistingEngine(
        _ engine: AVPlayerEngine,
        item: AVPlayerItem
    ) {
        if let old = engine.player.currentItem {
            stopObservingPlayerItem(old)
        }
        PlaybackBufferPolicy.configure(item: item)
        startObservingPlayerItem(item)
        // The duration callback binds the current item — the engine rebinds
        // it on replace, and the view refreshes its callbacks.
        engine.replace(item: item)
        videoPlayerView?.rebind(engine: engine)
        engine.play()
    }

    func getOrCreatePlayerView() -> VideoPlayerView {
        if let existing = videoPlayerView {
            return existing
        }
        let playerView = VideoPlayerView()
        playerView
            .translatesAutoresizingMaskIntoConstraints
            = false
        playerView.delegate = self
        playerContainer.addSubview(playerView)
        applyEdgeConstraints(playerView, to: playerContainer)
        videoPlayerView = playerView
        playerView.setCaptionTracks(
            captionTracks,
            activeLanguage: activeSubtitleLanguage
        )
        playerView.onCCTapped = { [weak self] in
            self?.showSubtitlePicker()
        }
        return playerView
    }

    func configureSponsorBlock(
        on playerView: VideoPlayerView
    ) {
        sponsorBlock.attach(to: playerView)
        playerView.onTimeUpdate = { [weak self] time in
            self?.sponsorBlock.checkTime(time)
            NowPlayingService.shared.updatePosition(time)
            self?.videoPlayerView?.updateSubtitle(at: time)
        }
        playerView.onSkipTapped = { [weak self] in
            self?.sponsorBlock.skipCurrentSegment()
        }
        if !sponsorBlock.segments.isEmpty {
            playerView.setSponsorSegments(
                sponsorBlock.segments
            )
        }
    }

    func beginNowPlayingSession(duration: Double) {
        guard let engine = videoPlayerView?.engine else {
            return
        }
        NowPlayingService.shared.beginSession(
            engine: engine,
            metadata: NowPlayingMetadata(
                title: initialVideo.title,
                channelName: initialVideo.channelName,
                duration: duration,
                artworkURL: URL(string: initialVideo.thumbnailURL)
            ),
            onNext: { [weak self] in
                self?.playNextFromRemote()
            },
            onPrevious: { [weak self] in
                self?.previousFromRemote()
            }
        )
    }

    func resetPlaybackSurfaces() {
        videoPlayerView?.engine?.pause()
        if let existing =
            videoPlayerView?.player?.currentItem {
            stopObservingPlayerItem(existing)
        }
        videoPlayerView?.detach()
        NowPlayingService.shared.endSession()
    }
}
