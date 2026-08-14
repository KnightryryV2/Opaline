import UIKit

// MARK: - Sleep timer
//
// One button: dims the screen and arms the timer, tapped again cancels.
// Like the audio-only button it doubles as the indicator — accent-tinted
// while the timer runs, because nothing else on screen says so.

extension VideoPlayerView {
    func configureSleepButton() {
        sleepButton.setImage(
            PlayerIcons.playerIcon("icon_moon_fill", size: 24)
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        sleepButton.accessibilityLabel = "player.sleepTimer".localized
        sleepButton.translatesAutoresizingMaskIntoConstraints = false
        sleepButton.addTarget(
            self,
            action: #selector(sleepTapped),
            for: .touchUpInside
        )
        controlsView.addSubview(sleepButton)
        NSLayoutConstraint.activate([
            sleepButton.centerYAnchor.constraint(
                equalTo: settingsButton.centerYAnchor
            ),
            sleepButton.trailingAnchor.constraint(
                equalTo: audioOnlyButton.leadingAnchor, constant: -4
            ),
            sleepButton.widthAnchor.constraint(equalToConstant: 36),
            sleepButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        refreshSleepState()
    }

    /// Sits between the video and the controls, so the buttons that turn it
    /// off stay at full contrast. Never takes touches.
    func setupNightDim() {
        nightDimView.backgroundColor = .black
        nightDimView.alpha = 0
        nightDimView.isUserInteractionEnabled = false
        nightDimView.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(nightDimView, belowSubview: controlsView)
        NSLayoutConstraint.activate([
            nightDimView.topAnchor.constraint(equalTo: topAnchor),
            nightDimView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nightDimView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nightDimView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc
    private func sleepTapped() {
        let sleep = SleepTimer.shared
        if sleep.isArmed {
            sleep.cancel()
        } else {
            sleep.onExpire = { [weak self] in
                self?.player?.pause()
                self?.refreshSleepState()
            }
            sleep.arm()
        }
        refreshSleepState()
        scheduleAutoHide()
    }

    /// Paints the button and the overlay from the timer's state — the timer
    /// outlives any single video, so this runs on every (re)attach too.
    func refreshSleepState() {
        let sleep = SleepTimer.shared
        sleepButton.tintColor = sleep.isArmed
            ? ThemeManager.shared.accent
            : .white
        UIView.animate(withDuration: 0.25) {
            self.nightDimView.alpha = sleep.overlayAlpha
        }
    }
}
