import Foundation

public protocol SearchService: Sendable {
    func search(query: String, requiredDrivers: [String], offsetByDriver: [String: Int]) async throws -> ([BookPreview], [String: Int], [String: Bool])
}

public struct MockSearchService: SearchService {
    private let source: [BookPreview]

    public init(source: [BookPreview] = DemoData.searchResults) {
        self.source = source
    }

    public func search(
        query: String,
        requiredDrivers: [String],
        offsetByDriver: [String: Int]
    ) async throws -> ([BookPreview], [String: Int], [String: Bool]) {
        try await Task.sleep(nanoseconds: 150_000_000)

        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else {
            return ([], offsetByDriver, Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, true) }))
        }

        let filtered = source.filter { preview in
            requiredDrivers.contains(preview.driver) && (
                preview.name.lowercased().contains(normalized) ||
                preview.author.lowercased().contains(normalized) ||
                preview.seriesName.lowercased().contains(normalized)
            )
        }

        var newOffsets = offsetByDriver
        var hasNext = Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, false) })

        for driver in requiredDrivers {
            let currentOffset = offsetByDriver[driver, default: 0]
            let driverItems = filtered.filter { $0.driver == driver }
            let consumed = min(driverItems.count, currentOffset + 5)
            newOffsets[driver] = consumed
            hasNext[driver] = consumed < driverItems.count
        }

        return (filtered, newOffsets, hasNext)
    }
}

public struct LiveSearchService: SearchService {
    private let loader: LoaderService
    private let perRequestLimit: Int

    public init(loader: LoaderService = DefaultLoaderService(), perRequestLimit: Int = 10) {
        self.loader = loader
        self.perRequestLimit = perRequestLimit
    }

    public func search(
        query: String,
        requiredDrivers: [String],
        offsetByDriver: [String: Int]
    ) async throws -> ([BookPreview], [String: Int], [String: Bool]) {
        var state: [String: (offset: Int, canLoadNext: Bool)] = [:]
        for driver in requiredDrivers {
            state[driver] = (offsetByDriver[driver, default: 0], true)
        }

        let response = try await loader.searchBooks(
            query: query,
            requiredDrivers: requiredDrivers,
            searchState: state,
            limit: perRequestLimit
        )

        var newOffsets: [String: Int] = offsetByDriver
        var canLoadNext: [String: Bool] = [:]

        for (driver, st) in response.searchState {
            newOffsets[driver] = st.offset
            canLoadNext[driver] = st.canLoadNext
        }

        return (response.results, newOffsets, canLoadNext)
    }
}
