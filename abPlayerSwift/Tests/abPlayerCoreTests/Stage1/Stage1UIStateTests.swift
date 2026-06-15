import Testing
@testable import abPlayerCore
import Foundation

private struct FakeBookDetailsService: BookDetailsService {
    func fetchBook(url: String) async throws -> Book {
        let preview = DemoData.searchResults.first(where: { $0.url == url })
        return Book(
            id: abs(url.hashValue),
            author: preview?.author ?? "Unknown",
            name: preview?.name ?? "Book",
            seriesName: preview?.seriesName ?? "",
            numberInSeries: preview?.numberInSeries ?? "",
            description: "",
            reader: preview?.reader ?? "",
            duration: preview?.duration ?? "",
            url: url,
            preview: preview?.preview ?? "",
            driver: preview?.driver ?? "",
            items: [BookItem(fileURL: url + "#audio", fileIndex: 0, title: "Chapter 1", startTime: 0, endTime: 1)]
        )
    }
}

@MainActor
private func stage1Environment(seedBooks: [Book] = DemoData.books) -> AppEnvironment {
    let store = InMemoryStore(seedBooks: seedBooks)
    return AppEnvironment(
        searchService: MockSearchService(),
        libraryService: DefaultLibraryService(store: store),
        downloadService: MockDownloadQueueService(store: store),
        bookDetailsService: FakeBookDetailsService(),
        settingsService: UserDefaultsSettingsService(),
        drivers: DemoData.drivers
    )
}

@MainActor
struct Stage1UIStateTests {
    @Test
    func pageSwitchingWorks() {
        let store = AppStateStore(environment: .default())
        #expect(store.currentPage == .library)

        store.open(page: .search)
        #expect(store.currentPage == .search)

        store.open(page: .downloads)
        #expect(store.currentPage == .downloads)
    }

    @Test
    func libraryFilteringUsesQueryTokens() async {
        let store = AppStateStore(environment: stage1Environment())
        await store.loadLibrary()
        store.libraryQuery = "Лев Толстой"

        let filtered = store.filteredBooks()
        #expect(filtered.count == 1)
        #expect(filtered.first?.author == "Лев Толстой")
    }

    @Test
    func searchProducesResultsAndCanAddBook() async throws {
        let store = AppStateStore(environment: stage1Environment(seedBooks: []))
        store.searchQuery = "война"
        await store.runSearch(reset: true)

        #expect(!store.searchResults.isEmpty)

        let first = try #require(store.searchResults.first)
        await store.addBook(first)
        await store.loadLibrary()

        #expect(store.books.contains(where: { $0.url == first.url }))
    }

    @Test
    func defaultEnvironmentStartsWithEmptyLibrary() async {
        let store = AppStateStore(environment: .default())
        await store.loadLibrary()
        #expect(store.books.isEmpty)
    }
}
