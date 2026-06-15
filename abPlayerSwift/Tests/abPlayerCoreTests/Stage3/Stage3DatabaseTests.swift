import Foundation
import Testing
@testable import abPlayerCore

struct Stage3DatabaseTests {
    private func makePath(_ name: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
            .path
    }

    @Test
    func sqliteCrudAndFiltering() async throws {
        let path = makePath("abp_stage3_1.sqlite")
        try? FileManager.default.removeItem(atPath: path)

        let repo = try SQLiteRepository(path: path)
        let book = Book(
            id: 77,
            author: "Лев Толстой",
            name: "Война и мир",
            seriesName: "Русская классика",
            numberInSeries: "1",
            description: "desc",
            reader: "reader",
            duration: "10:00:00",
            url: "https://akniga.org/tolstoy-lev-voyna-i-mir",
            preview: "",
            driver: "AKniga",
            status: .new,
            favorite: false,
            downloaded: true,
            downloading: false,
            addingDate: Date()
        )
        try repo.upsert(book: book)

        let all = try repo.allBooks()
        #expect(all.count == 1)

        let filtered = try repo.allBooks(filter: LibraryFilter(author: "Лев Толстой"))
        #expect(filtered.count == 1)

        let empty = try repo.allBooks(filter: LibraryFilter(author: "Неизвестный"))
        #expect(empty.isEmpty)
    }

    @Test
    func sqliteFavoriteStatusAndStopFlagUpdates() async throws {
        let path = makePath("abp_stage3_2.sqlite")
        try? FileManager.default.removeItem(atPath: path)

        let repo = try SQLiteRepository(path: path)
        try repo.upsert(book: DemoData.books[0])

        try repo.setFavorite(bookID: DemoData.books[0].id, value: false)
        try repo.setStatus(bookID: DemoData.books[0].id, status: .finished)
        try repo.setStopFlag(bookID: DemoData.books[0].id, item: 2, time: 45)

        let rows = try repo.allBooks()
        let updated = try #require(rows.first)
        #expect(updated.favorite == false)
        #expect(updated.status == .finished)
        #expect(updated.stopFlag.item == 2)
        #expect(updated.stopFlag.time == 45)
    }

    @Test
    func sqliteLibraryServiceAddAndRemove() async throws {
        let path = makePath("abp_stage3_3.sqlite")
        try? FileManager.default.removeItem(atPath: path)

        let repo = try SQLiteRepository(path: path)
        let service = SQLiteLibraryService(repository: repo)

        let preview = BookPreview(
            author: "Author",
            name: "Name",
            url: "https://knigavuhe.org/book/name",
            driver: "KnigaVUhe"
        )

        let added = try await service.add(preview: preview)
        let booksAfterAdd = await service.allBooks()
        #expect(booksAfterAdd.contains(where: { $0.id == added.id }))

        await service.remove(bookID: added.id)
        let booksAfterRemove = await service.allBooks()
        #expect(!booksAfterRemove.contains(where: { $0.id == added.id }))
    }
}
