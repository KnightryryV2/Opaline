import Foundation

/// Resolves the active strings bundle. Following the system uses the main
/// bundle (iOS picks the `.lproj` itself); an in-app override resolves that
/// language's bundle directly — required on iOS 12, where per-app language
/// in the Settings app does not exist (it arrived in iOS 13).
final class LocalizationManager {
    static let shared = LocalizationManager()

    private(set) var bundle: Bundle = .main

    private init() {
        reload()
    }

    /// Re-resolves the bundle after a language change. UI built before the
    /// change keeps its strings — the caller decides between rebuilding the
    /// root controller and a restart prompt (see the localization plan).
    func reload() {
        guard let code = AppLanguage.override?.rawValue,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else {
            bundle = .main
            return
        }
        bundle = localized
    }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

extension String {
    /// Localized UI string — ALL user-facing text goes through this, never
    /// `NSLocalizedString` directly: the in-app language override needs
    /// [[LocalizationManager]]'s bundle resolution. Missing keys fall back
    /// to English (`.strings` runtime behavior), then to the key itself.
    var localized: String {
        LocalizationManager.shared.localized(self)
    }

    /// Localized format string applied to `args`. Use positional
    /// placeholders (`%1$@`) whenever a translation could reorder them.
    func localized(with args: CVarArg...) -> String {
        String(format: localized, arguments: args)
    }
}
