import Foundation

public actor SQLiteLibraryService: LibraryService {
    private let repository: SQLiteRepository

    public init(repository: SQLiteRepository) {
        self.repository = repository
    }

    public func allBooks() async -> [Book] {
        (try? repository.allBooks()) ?? []
    }

    public func book(by id: Int) async -> Book? {
        (try? repository.allBooks().first { $0.id == id }) ?? nil
    }

    public func toggleFavorite(bookID: Int) async -> Bool? {
        guard let book = await book(by: bookID) else { return nil }
        let next = !book.favorite
        try? repository.setFavorite(bookID: bookID, value: next)
        return next
    }

    public func setStatus(bookID: Int, status: BookStatus) async {
        try? repository.setStatus(bookID: bookID, status: status)
    }

    public func setStopFlag(bookID: Int, item: Int, time: Int) async {
        try? repository.setStopFlag(bookID: bookID, item: max(0, item), time: max(0, time))
    }

    public func add(preview: BookPreview) async throws -> Book {
        let current = try repository.allBooks()
        if current.contains(where: { $0.url == preview.url }) {
            throw CloneError.alreadyExists
        }

        let id = (current.map(\.id).max() ?? 0) + 1
        let book = Book(
            id: id,
            author: preview.author,
            name: preview.name,
            seriesName: preview.seriesName,
            numberInSeries: preview.numberInSeries,
            description: "",
            reader: preview.reader,
            duration: preview.duration,
            url: preview.url,
            preview: preview.preview,
            driver: preview.driver,
            items: [],
            status: .new,
            stopFlag: StopFlag(),
            favorite: false,
            downloaded: false,
            downloading: false,
            addingDate: Date()
        )
        try repository.upsert(book: book)
        return book
    }

    public func add(book: Book) async throws -> Book {
        var mutable = book
        let current = try repository.allBooks()
        if mutable.id <= 0 || current.contains(where: { $0.id == mutable.id }) {
            mutable.id = (current.map(\.id).max() ?? 0) + 1
        }
        try repository.upsert(book: mutable)
        return mutable
    }

    public func remove(bookID: Int) async {
        try? repository.remove(bookID: bookID)
    }

    public func exportStateData() async throws -> Data {
        throw CloneError.connectionIssue("Export/import is supported for in-memory persistent mode")
    }

    public func importStateData(_ data: Data) async throws {
        _ = data
        throw CloneError.connectionIssue("Export/import is supported for in-memory persistent mode")
    }
}
