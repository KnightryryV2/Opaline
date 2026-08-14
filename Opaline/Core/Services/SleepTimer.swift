import UIKit

/// Night mode: one tap dims the screen and arms a timer that stops playback
/// (#44). Screen brightness is device-wide state we borrow, so this type is
/// the single owner of the user's entry value — every path that ends the
/// dim goes through `restoreBrightness()`, and the value is mirrored in the
/// defaults so even a kill during playback cannot strand the screen dark.
final class SleepTimer {
    static let shared = SleepTimer()

    /// Minutes until playback stops. Bedtime-length by default so the
    /// feature is useful before anyone opens Settings.
    static var minutes: Int {
        get {
            UserDefaults.standard.object(
                forKey: UserDefaultsKeys.Player.sleepTimerMinutes
            ) as? Int ?? 30
        }
        set {
            UserDefaults.standard.set(
                newValue, forKey: UserDefaultsKeys.Player.sleepTimerMinutes
            )
        }
    }

    /// How far to dim, in percent of the current brightness.
    static var dimLevel: Int {
        get {
            UserDefaults.standard.object(
                forKey: UserDefaultsKeys.Player.sleepDimLevel
            ) as? Int ?? 60
        }
        set {
            UserDefaults.standard.set(
                newValue, forKey: UserDefaultsKeys.Player.sleepDimLevel
            )
        }
    }

    static let minuteOptions = [10, 15, 30, 45, 60, 90]
    static let dimOptions = [30, 45, 60, 75, 90]

    /// Runs on expiry, on the main thread — the player pauses from here.
    /// Set when arming, so it always belongs to the current player.
    var onExpire: (() -> Void)?

    private(set) var isArmed = false

    /// Extra darkening laid over the video: brightness alone stops at the
    /// system minimum, which is still bright in a dark room.
    var overlayAlpha: CGFloat {
        isArmed ? CGFloat(Self.dimLevel) / 100 * 0.5 : 0
    }

    private var timer: Timer?
    private var originalBrightness: CGFloat?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(suspendDim),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(syncDim),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(suspendDim),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - Arming

    func toggle() {
        if isArmed {
            cancel()
        } else {
            arm()
        }
    }

    func arm() {
        isArmed = true
        applyDim()
        timer?.invalidate()
        // A background-audio session keeps the run loop alive, so the timer
        // still fires with the screen off. A fully suspended app does not
        // resume to fire it — playback there has already stopped anyway.
        timer = Timer.scheduledTimer(
            timeInterval: Double(Self.minutes) * 60,
            target: self,
            selector: #selector(expire),
            userInfo: nil,
            repeats: false
        )
        AppLog.player("sleep timer armed: \(Self.minutes) min")
    }

    func cancel() {
        guard isArmed else {
            return
        }
        timer?.invalidate()
        timer = nil
        isArmed = false
        onExpire = nil
        restoreBrightness()
    }

    @objc
    private func expire() {
        AppLog.player("sleep timer expired")
        let pause = onExpire
        cancel()
        pause?()
    }

    // MARK: - Brightness

    /// Drops brightness but never to zero: the PiP code reads a pitch-black
    /// screen as "the device is locked".
    private func applyDim() {
        if originalBrightness == nil {
            let current = UIScreen.main.brightness
            originalBrightness = current
            UserDefaults.standard.set(
                Double(current), forKey: UserDefaultsKeys.Player.sleepBrightnessBackup
            )
        }
        guard let original = originalBrightness else {
            return
        }
        UIScreen.main.brightness = max(
            0.02, original * (1 - CGFloat(Self.dimLevel) / 100)
        )
    }

    func restoreBrightness() {
        guard let original = originalBrightness else {
            return
        }
        UIScreen.main.brightness = original
        // The write does not stick while the screen is off (the timer can
        // expire with the device locked and the audio still playing), so the
        // debt is only written off once it visibly took.
        guard UIScreen.main.brightness > 0 else {
            return
        }
        originalBrightness = nil
        UserDefaults.standard.removeObject(
            forKey: UserDefaultsKeys.Player.sleepBrightnessBackup
        )
    }

    /// Gives the brightness back while the player is not the thing on screen
    /// (background, PiP) without disarming — the timer is what the user set.
    @objc
    func suspendDim() {
        // A pitch-black screen means the device is locking. Writing
        // brightness there is both pointless and harmful: the PiP code reads
        // exactly that zero to tell a lock from an app switch. The entry
        // value stays remembered — `syncDim` puts it back on the way in.
        guard UIScreen.main.brightness > 0 else {
            return
        }
        restoreBrightness()
    }

    /// Back on screen: dim again if the timer is still running, otherwise
    /// hand back whatever brightness is still owed.
    @objc
    func syncDim() {
        if isArmed {
            applyDim()
        } else {
            restoreBrightness()
        }
    }

    /// Last resort: the app died while dimmed (jetsam, crash, force quit
    /// mid-video) and nothing got to put the brightness back. Called once at
    /// launch, before any UI can dim again.
    func restoreBrightnessAfterUncleanExit() {
        let key = UserDefaultsKeys.Player.sleepBrightnessBackup
        guard let saved = UserDefaults.standard.object(forKey: key) as? Double else {
            return
        }
        AppLog.player("restoring brightness left dim by a previous run")
        UIScreen.main.brightness = CGFloat(saved)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
