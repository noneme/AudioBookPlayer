import Foundation

public protocol LoaderService: Sendable {
    func searchBooks(query: String, requiredDrivers: [String], searchState: [String: (offset: Int, canLoadNext: Bool)], limit: Int) async throws -> (results: [BookPreview], searchState: [String: (offset: Int, canLoadNext: Bool)])
    func bookByURL(_ url: String) async throws -> Book
    func bookSeries(url: String) async throws -> [BookPreview]
}

public struct DefaultLoaderService: LoaderService {
    private let registry: DriverRegistry

    public init(registry: DriverRegistry = .default()) {
        self.registry = registry
    }

    public func searchBooks(
        query: String,
        requiredDrivers: [String],
        searchState: [String: (offset: Int, canLoadNext: Bool)],
        limit: Int
    ) async throws -> (results: [BookPreview], searchState: [String: (offset: Int, canLoadNext: Bool)]) {
        if query.hasPrefix("https://") {
            let book = try await bookByURL(query)
            let preview = BookPreview(
                author: book.author,
                name: book.name,
                seriesName: book.seriesName,
                numberInSeries: book.numberInSeries,
                reader: book.reader,
                duration: book.duration,
                url: book.url,
                preview: book.preview,
                driver: book.driver
            )
            return ([preview], searchState)
        }

        var newState = searchState
        let activeDrivers = registry.drivers.filter {
            requiredDrivers.contains($0.name) && (searchState[$0.name]?.canLoadNext ?? true)
        }

        let limitPerDriver = max(1, limit / max(1, activeDrivers.count))
        var output: [BookPreview] = []

        for driver in activeDrivers {
            let offset = searchState[driver.name]?.offset ?? 0
            let books = try await driver.searchBooks(query: query, limit: limitPerDriver, offset: offset)
            output.append(contentsOf: books)
            let consumed = offset + books.count
            let hasNext = books.count >= limitPerDriver
            newState[driver.name] = (offset: consumed, canLoadNext: hasNext)
        }

        return (output, newState)
    }

    public func bookByURL(_ url: String) async throws -> Book {
        guard let driver = DriverLookup.suitableDriver(for: url, in: registry.drivers) else {
            throw CloneError.noSuitableDriver
        }
        return try await driver.getBook(url: url)
    }

    public func bookSeries(url: String) async throws -> [BookPreview] {
        guard let driver = DriverLookup.suitableDriver(for: url, in: registry.drivers) else {
            throw CloneError.noSuitableDriver
        }
        return try await driver.getBookSeries(url: url)
    }
}
