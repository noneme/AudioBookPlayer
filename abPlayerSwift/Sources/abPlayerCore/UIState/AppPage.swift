import Foundation

public enum AppPage: String, CaseIterable, Sendable {
    case library
    case bookPlayer
    case search
    case downloads
    case settings
}

public enum LibrarySection: String, CaseIterable, Sendable {
    case all
    case favorites
    case downloaded
    case new
    case started
    case finished
}
