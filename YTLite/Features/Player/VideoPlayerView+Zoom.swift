import AVFoundation
import UIKit

// MARK: - Fullscreen Pinch Zoom

extension VideoPlayerView {
    /// Hard ceiling for pinch zoom, relative to aspect-fit (200%).
    static let maxPinchZoom: CGFloat = 2

    /// Auto zoom-to-fill setting (Playback settings menu).
    static var autoZoomToFill: Bool {
        UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.Player.autoZoomToFill
        )
    }

    /// Layer currently presenting video: `sampleBufferLayer` when a
    /// software-decode engine is attached (renders into an
    /// `AVSampleBufferDisplayLayer` hosted as a plain `CALayer`), else
    /// `playerLayer`. Pinch-zoom targets this instead of hardcoding
    /// `playerLayer` so both playback paths share one zoom implementation.
    var activeVideoLayer: CALayer { sampleBufferLayer ?? playerLayer }

    /// Scale at which the video covers the whole view (no bars).
    /// 1 when the video already fills or its size is not yet known.
    var fillZoom: CGFloat {
        guard bounds.width > 0, bounds.height > 0 else {
            return 1
        }
        let rect: CGRect
        if sampleBufferLayer != nil {
            // AVSampleBufferDisplayLayer has no `videoRect` — derive the
            // same aspect-fit rect from the manifest-reported pixel size.
            guard let size = engine?.naturalSize, size.width > 0, size.height > 0 else {
                return 1
            }
            rect = AVMakeRect(aspectRatio: size, insideRect: bounds)
        } else {
            rect = playerLayer.videoRect
        }
        guard rect.width > 0, rect.height > 0 else {
            return 1
        }
        return max(
            bounds.width / rect.width,
            bounds.height / rect.height
        )
    }

    /// Animate to the fill scale when the setting is on and the user
    /// hasn't pinched manually. Called on fullscreen entry and whenever
    /// the layer (re)becomes ready — covers autoplay video changes.
    func applyAutoZoomIfNeeded() {
        guard Self.autoZoomToFill, isFullscreen,
              videoZoom <= 1.01 || zoomIsAuto else {
            return
        }
        let fill = fillZoom
        let target = fill > 1.01 ? fill : 1
        guard abs(target - videoZoom) > 0.01 else {
            return
        }
        setZoom(target, animated: true)
        zoomIsAuto = target > 1
    }

    /// AVPlayer path only: `AVSampleBufferDisplayLayer` also has
    /// `isReadyForDisplay`, but as a KVO-observable public property it's
    /// iOS 17.4+ only. The sample-buffer path doesn't need it anyway — its
    /// `fillZoom` comes from the manifest's `naturalSize`, known synchronously
    /// at attach, so `attach(engine:)` calls `applyAutoZoomIfNeeded()` directly.
    func observeReadyForDisplay() {
        readyObservation = playerLayer.observe(
            \.isReadyForDisplay,
            options: [.new]
        ) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else {
                return
            }
            DispatchQueue.main.async {
                self?.applyAutoZoomIfNeeded()
            }
        }
    }

    func handleFullscreenPinch(
        _ gesture: UIPinchGestureRecognizer
    ) {
        switch gesture.state {
        case .began:
            pinchStartZoom = videoZoom
            zoomIsAuto = false
        case .changed:
            let limit = max(Self.maxPinchZoom, fillZoom)
            let proposed = pinchStartZoom * gesture.scale
            setZoom(
                min(max(proposed, 1), limit),
                animated: false
            )
            showZoomHUD()
        case .ended, .cancelled, .failed:
            finishPinch(endScale: gesture.scale)
        default:
            break
        }
    }

    private func finishPinch(endScale: CGFloat) {
        // Pinch-in while already at 100% keeps the old
        // exit-fullscreen shortcut.
        if pinchStartZoom <= 1.01, endScale < 0.8 {
            hideZoomHUD(after: 0)
            delegate?.videoPlayerViewDidTapFullscreen(self)
            return
        }
        let snapped = snappedZoom(videoZoom)
        if snapped != videoZoom {
            setZoom(snapped, animated: true)
        }
        showZoomHUD()
        hideZoomHUD(after: 0.8)
    }

    /// Snap near-fit back to 100% and near-fill onto the exact
    /// fill scale so bars disappear completely.
    private func snappedZoom(_ zoom: CGFloat) -> CGFloat {
        let fill = fillZoom
        if fill > 1.01, abs(zoom - fill) < fill * 0.08 {
            return fill
        }
        if zoom < 1.05 {
            return 1
        }
        return zoom
    }

    func setZoom(_ zoom: CGFloat, animated: Bool) {
        videoZoom = zoom
        let scale = CGAffineTransform(
            scaleX: zoom,
            y: zoom
        )
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
            activeVideoLayer.setAffineTransform(scale)
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeVideoLayer.setAffineTransform(scale)
        CATransaction.commit()
    }

    // MARK: - Zoom HUD

    private func showZoomHUD() {
        if zoomLabel.superview == nil {
            setupZoomLabel()
        }
        zoomHUDWorkItem?.cancel()
        zoomLabel.text = zoomHUDText()
        zoomLabel.alpha = 1
    }

    private func zoomHUDText() -> String {
        let fill = fillZoom
        if fill > 1.01, abs(videoZoom - fill) < 0.01 {
            return "  Fill  "
        }
        let percent = Int((videoZoom * 100).rounded())
        return "  \(percent)%  "
    }

    func hideZoomHUD(after delay: TimeInterval) {
        zoomHUDWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) {
                self?.zoomLabel.alpha = 0
            }
        }
        zoomHUDWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private func setupZoomLabel() {
        addSubview(zoomLabel)
        NSLayoutConstraint.activate([
            zoomLabel.centerXAnchor.constraint(
                equalTo: centerXAnchor
            ),
            zoomLabel.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: 24
            ),
            zoomLabel.heightAnchor.constraint(
                equalToConstant: 28
            )
        ])
    }
}
