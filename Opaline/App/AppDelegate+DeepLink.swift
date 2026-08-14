import UIKit

/// Handles `ytlite://` and youtube.com links passed to the app via
/// `application(_:open:options:)`. The pre-scene, single-window
/// `AppDelegate` hook is correct here (see `CLAUDE.md`: no scene delegates,
/// iOS 12 is the primary target).
extension AppDelegate {
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard let videoId = YouTubeLinkParser.videoId(from: url) else {
            return false
        }
        guard window?.rootViewController is RootContainerViewController else {
            // Splash/auth still up — replay once showMain() runs.
            pendingDeepLink = videoId
            return true
        }
        VideoRouter.shared.openVideoId(videoId)
        return true
    }

    func replayPendingDeepLinkIfNeeded() {
        guard let videoId = pendingDeepLink else {
            return
        }
        pendingDeepLink = nil
        VideoRouter.shared.openVideoId(videoId)
    }
}
