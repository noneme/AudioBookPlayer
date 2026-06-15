import Foundation

public enum CloneError: LocalizedError, Sendable {
    case notFound
    case noSuitableDriver
    case connectionIssue(String)
    case notAuthenticated
    case alreadyExists
    case notDownloaded

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Book not found"
        case .noSuitableDriver:
            return "No suitable driver"
        case let .connectionIssue(reason):
            return "Connection issue: \(reason)"
        case .notAuthenticated:
            return "Driver not authenticated"
        case .alreadyExists:
            return "Book already exists"
        case .notDownloaded:
            return "Book not downloaded"
        }
    }
}
