import Foundation

public enum AppAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum AppLanguageMode: String, Codable, CaseIterable, Sendable {
    case system
    case ru
    case en
}

public enum AppSettingsKeys {
    public static let downloadDirectoryPath = "abp.settings.download_directory_path"
    public static let appearanceMode = "abp.settings.appearance_mode"
    public static let appLanguage = "abp.settings.app_language"
    public static let bookmateAuthToken = "abp.settings.bookmate_auth_token"
}

public protocol SettingsService: Sendable {
    func downloadDirectoryPath() async -> String
    func setDownloadDirectoryPath(_ path: String) async throws
    func appearanceMode() async -> AppAppearanceMode
    func setAppearanceMode(_ mode: AppAppearanceMode) async
    func appLanguage() async -> AppLanguageMode
    func setAppLanguage(_ mode: AppLanguageMode) async
    func bookmateAuthToken() async -> String
    func setBookmateAuthToken(_ token: String) async
    func clearBookmateAuthToken() async
}

public actor UserDefaultsSettingsService: SettingsService {
    private let defaults: UserDefaults
    private let fm: FileManager
    private let defaultPath: String

    public init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fm = fileManager
        self.defaultPath = Self.buildDefaultPath(fileManager: fileManager)
    }

    public func downloadDirectoryPath() async -> String {
        if let saved = defaults.string(forKey: AppSettingsKeys.downloadDirectoryPath), !saved.isEmpty {
            let normalized = Self.normalizeDownloadDirectoryPath(saved, fileManager: fm, defaultPath: defaultPath)
            try? ensureDirectoryExists(normalized)
            if normalized != saved {
                defaults.set(normalized, forKey: AppSettingsKeys.downloadDirectoryPath)
            }
            return normalized
        }
        try? ensureDirectoryExists(defaultPath)
        defaults.set(defaultPath, forKey: AppSettingsKeys.downloadDirectoryPath)
        return defaultPath
    }

    public func setDownloadDirectoryPath(_ path: String) async throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CloneError.notFound
        }
        let normalized = Self.normalizeDownloadDirectoryPath(trimmed, fileManager: fm, defaultPath: defaultPath)
        try ensureDirectoryExists(normalized)
        defaults.set(normalized, forKey: AppSettingsKeys.downloadDirectoryPath)
    }

    public func appearanceMode() async -> AppAppearanceMode {
        guard let raw = defaults.string(forKey: AppSettingsKeys.appearanceMode),
              let mode = AppAppearanceMode(rawValue: raw)
        else {
            defaults.set(AppAppearanceMode.system.rawValue, forKey: AppSettingsKeys.appearanceMode)
            return .system
        }
        return mode
    }

    public func setAppearanceMode(_ mode: AppAppearanceMode) async {
        defaults.set(mode.rawValue, forKey: AppSettingsKeys.appearanceMode)
    }

    public func appLanguage() async -> AppLanguageMode {
        guard let raw = defaults.string(forKey: AppSettingsKeys.appLanguage),
              let mode = AppLanguageMode(rawValue: raw)
        else {
            defaults.set(AppLanguageMode.system.rawValue, forKey: AppSettingsKeys.appLanguage)
            return .system
        }
        return mode
    }

    public func setAppLanguage(_ mode: AppLanguageMode) async {
        defaults.set(mode.rawValue, forKey: AppSettingsKeys.appLanguage)
    }

    public func bookmateAuthToken() async -> String {
        defaults.string(forKey: AppSettingsKeys.bookmateAuthToken) ?? ""
    }

    public func setBookmateAuthToken(_ token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: AppSettingsKeys.bookmateAuthToken)
    }

    public func clearBookmateAuthToken() async {
        defaults.removeObject(forKey: AppSettingsKeys.bookmateAuthToken)
    }

    private static func buildDefaultPath(fileManager: FileManager) -> String {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let root = docs ?? URL(fileURLWithPath: NSHomeDirectory())
        return root.appendingPathComponent("abPlayerDownloads", isDirectory: true).path
    }

    private static func normalizeDownloadDirectoryPath(_ path: String, fileManager: FileManager, defaultPath: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultPath }

#if os(iOS)
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return defaultPath
        }

        let docsPath = docs.path
        if trimmed == docsPath || trimmed.hasPrefix(docsPath + "/") {
            return trimmed
        }

        if let range = trimmed.range(of: "/Documents/") {
            let suffix = String(trimmed[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if suffix.isEmpty {
                return defaultPath
            }
            return docs.appendingPathComponent(suffix, isDirectory: true).path
        }

        return defaultPath
#else
        return trimmed
#endif
    }

    private func ensureDirectoryExists(_ path: String) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw CloneError.connectionIssue("Path is not a directory")
            }
            return
        }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
