import Foundation
import abPlayerCore

enum L10n {
    static let fallbackLocale = Locale(identifier: "en")

    private static let supportedLanguageCodes: Set<String> = ["en", "ru"]

    static func locale(for mode: AppLanguageMode) -> Locale {
        switch mode {
        case .system:
            if let code = resolvedSystemLanguageCode() {
                return Locale(identifier: code)
            }
            return fallbackLocale
        case .ru:
            return Locale(identifier: "ru")
        case .en:
            return Locale(identifier: "en")
        }
    }

    static func key(_ key: String, mode: AppLanguageMode) -> String {
        let bundle = bundle(for: mode)
        let localized = NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
        if localized != key {
            return localized
        }
        return NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
    }

    static func key(_ key: String) -> String {
        self.key(key, mode: .system)
    }

    static func status(_ status: DownloadEntry.Status, mode: AppLanguageMode) -> String {
        key("download.status.\(status.rawValue)", mode: mode)
    }

    private static func bundle(for mode: AppLanguageMode) -> Bundle {
        let code: String?
        switch mode {
        case .system:
            code = resolvedSystemLanguageCode()
        case .ru:
            code = "ru"
        case .en:
            code = "en"
        }

        guard let code,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .module
        }
        return bundle
    }

    private static func resolvedSystemLanguageCode() -> String? {
        for preferred in Locale.preferredLanguages {
            let code = preferred
                .split(separator: "-")
                .first?
                .lowercased() ?? ""
            if supportedLanguageCodes.contains(code) {
                return code
            }
        }
        return nil
    }
}
