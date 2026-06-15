import Foundation

public protocol BookDetailsService: Sendable {
    func fetchBook(url: String) async throws -> Book
}

public struct DefaultBookDetailsService: BookDetailsService {
    private let loader: LoaderService

    public init(loader: LoaderService = DefaultLoaderService()) {
        self.loader = loader
    }

    public func fetchBook(url: String) async throws -> Book {
        try await loader.bookByURL(url)
    }
}
