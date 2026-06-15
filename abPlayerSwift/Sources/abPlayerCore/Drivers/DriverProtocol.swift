import Foundation

public protocol DriverProtocol: Sendable {
    var name: String { get }
    var siteURL: String { get }
    var isLicensed: Bool { get }
    var isAuthenticated: Bool { get }

    func canHandle(url: String) -> Bool
    func getBook(url: String) async throws -> Book
    func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview]
    func getBookSeries(url: String) async throws -> [BookPreview]
}

public enum DriverLookup {
    public static func suitableDriver(for url: String, in drivers: [DriverProtocol]) -> DriverProtocol? {
        drivers.first { $0.canHandle(url: url) }
    }
}
