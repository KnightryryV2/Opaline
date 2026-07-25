import AVFoundation
import UIKit

// MARK: - Stats for nerds

extension WatchViewController {
    func toggleStatsOverlay() {
        if statsOverlay != nil {
            hideStatsOverlay()
        } else {
            showStatsOverlay()
        }
    }

    func hideStatsOverlay() {
        statsOverlay?.stop()
        statsOverlay?.removeFromSuperview()
        statsOverlay = nil
    }

    private func showStatsOverlay() {
        guard let playerView = videoPlayerView else {
            return
        }
        let overlay = StatsOverlayView()
        overlay.provider = { [weak self] in
            self?.statsText() ?? ""
        }
        overlay.onClose = { [weak self] in
            self?.hideStatsOverlay()
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        playerView.addSubview(overlay)
        let safeArea = playerView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(
                equalTo: safeArea.topAnchor, constant: 8
            ),
            overlay.leadingAnchor.constraint(
                equalTo: safeArea.leadingAnchor, constant: 8
            ),
            overlay.trailingAnchor.constraint(
                lessThanOrEqualTo: safeArea.trailingAnchor, constant: -8
            )
        ])
        statsOverlay = overlay
        overlay.start()
    }

    // MARK: - Text assembly

    private func statsText() -> String {
        let source = playbackFacade.activeVideoSource
        let item = videoPlayerView?.player?.currentItem
        var rows = [
            row(
                "Video ID / Source",
                "\(playbackFacade.currentVideoId ?? "?")"
                    + " / \(kindName(source?.kind))"
            ),
            row("Viewport / Frames", viewportValue(dropped: item)),
            row("Current / Selected", resolutionValue(item, source: source))
        ]
        if let codecs = source?.currentCodecs {
            rows.append(row("Codecs", codecs))
        }
        rows.append(row("Connection Speed", speedValue(item)))
        rows.append(row("Network Activity", transferredValue(item)))
        rows.append(row("Buffer Health", bufferValue(item)))
        // The sample-buffer engine has no AVPlayerItem, so the item-based rows
        // above read "?"; surface what the engine does expose.
        if item == nil, let engine = videoPlayerView?.engine {
            rows.append(row("Engine", "sample-buffer"))
            rows.append(row("Buffer (engine)", engineBufferValue(engine)))
            if let sbEngine = engine as? SampleBufferEngine {
                rows.append(row("Decode fps", decodeFpsValue(sbEngine)))
                rows.append(row("Decode cost", decodeCostValue(sbEngine)))
            }
        }
        return rows.joined(separator: "\n")
    }

    /// `SampleBufferEngine` is the only `PlayerEngine` with decode stats, so
    /// this file casts down to it rather than growing the protocol for one
    /// implementation. `decodeStats` is `nil` until the av01/dav1d path has
    /// completed a sampling window (or forever, on an avc1 sample-buffer
    /// track) — see `DecodeStatsSnapshot`.
    private func decodeFpsValue(_ engine: SampleBufferEngine) -> String {
        guard let stats = engine.decodeStats else {
            return "?"
        }
        return String(
            format: "%.1f fps, %d skipped, %dx%d",
            stats.decodeFps,
            stats.framesSkipped,
            stats.width,
            stats.height
        )
    }

    private func decodeCostValue(_ engine: SampleBufferEngine) -> String {
        guard let stats = engine.decodeStats else {
            return "?"
        }
        return String(format: "%.1f ms/frame", stats.msPerFrame)
    }

    private func engineBufferValue(_ engine: PlayerEngine) -> String {
        let now = CMTimeGetSeconds(engine.currentTime)
        let bufferedEnd = engine.loadedTimeRanges
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .filter { $0 >= now }
            .max()
        guard let bufferedEnd else {
            return "0.0 s"
        }
        return String(format: "%.1f s", bufferedEnd - now)
    }

    private func row(_ title: String, _ value: String) -> String {
        title.padding(toLength: 19, withPad: " ", startingAt: 0) + value
    }

    private func kindName(_ kind: VideoSourceKind?) -> String {
        switch kind {
        case .androidVR:
            return "android_vr"
        case .mwebPot:
            return "mweb+pot"
        case .progressive:
            return "progressive"
        case .auto:
            return "auto"
        case nil:
            return "?"
        }
    }

    private func viewportValue(dropped item: AVPlayerItem?) -> String {
        let playerView = videoPlayerView
        let size = playerView?.bounds.size ?? .zero
        let scale = playerView?.window?.screen.scale ?? UIScreen.main.scale
        let droppedFrames = (item?.accessLog()?.events ?? [])
            .reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
        return String(
            format: "%.0fx%.0f*%.2f / %d dropped",
            size.width,
            size.height,
            scale,
            droppedFrames
        )
    }

    /// Decoder-reported size (the truth) vs the picked ladder tier.
    private func resolutionValue(
        _ item: AVPlayerItem?, source: VideoSource?
    ) -> String {
        let size = item?.presentationSize ?? .zero
        let fps = source?.currentQuality?.fps.map { "@\($0)" } ?? ""
        let actual = size == .zero
            ? "?"
            : String(format: "%.0fx%.0f%@", size.width, size.height, fps)
        return "\(actual) / \(source?.currentQuality?.label ?? "?")"
    }

    private func speedValue(_ item: AVPlayerItem?) -> String {
        guard let bitrate = item?.accessLog()?.events.last?.observedBitrate,
              bitrate > 0 else {
            return "?"
        }
        return "\(Int(bitrate / 1_000)) Kbps"
    }

    private func transferredValue(_ item: AVPlayerItem?) -> String {
        let bytes = (item?.accessLog()?.events ?? [])
            .reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
        return String(
            format: "%.1f MB total", Double(bytes) / 1_048_576
        )
    }

    private func bufferValue(_ item: AVPlayerItem?) -> String {
        guard let item else {
            return "?"
        }
        let now = CMTimeGetSeconds(item.currentTime())
        let bufferedEnd = item.loadedTimeRanges
            .map { $0.timeRangeValue }
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .filter { $0 >= now }
            .max()
        guard let bufferedEnd else {
            return "0.0 s"
        }
        return String(format: "%.1f s", bufferedEnd - now)
    }
}
