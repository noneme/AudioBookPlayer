import Foundation

public protocol LibraryService: Sendable {
    func allBooks() async -> [Book]
    func book(by id: Int) async -> Book?
    func toggleFavorite(bookID: Int) async -> Bool?
    func setStatus(bookID: Int, status: BookStatus) async
    func setStopFlag(bookID: Int, item: Int, time: Int) async
    func add(preview: BookPreview) async throws -> Book
    func add(book: Book) async throws -> Book
    func remove(bookID: Int) async
    func exportStateData() async throws -> Data
    func importStateData(_ data: Data) async throws
}

public actor DefaultLibraryService: LibraryService {
    private let store: InMemoryStore

    public init(store: InMemoryStore) {
        self.store = store
    }

    public func allBooks() async -> [Book] {
        await store.allBooks()
    }

    public func book(by id: Int) async -> Book? {
        await store.allBooks().first { $0.id == id }
    }

    public func toggleFavorite(bookID: Int) async -> Bool? {
        guard var book = await store.allBooks().first(where: { $0.id == bookID }) else {
            return nil
        }
        book.favorite.toggle()
        await store.update(book: book)
        return book.favorite
    }

    public func setStatus(bookID: Int, status: BookStatus) async {
        guard var book = await store.allBooks().first(where: { $0.id == bookID }) else {
            return
        }
        book.status = status
        await store.update(book: book)
    }

    public func setStopFlag(bookID: Int, item: Int, time: Int) async {
        guard var book = await store.allBooks().first(where: { $0.id == bookID }) else {
            return
        }
        book.stopFlag = StopFlag(item: max(0, item), time: max(0, time))
        await store.update(book: book)
    }

    public func add(preview: BookPreview) async throws -> Book {
        let books = await store.allBooks()
        let nextID = (books.map(\.id).max() ?? 0) + 1
        let book = Book(
            id: nextID,
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
            status: .new,
            favorite: false,
            downloaded: false,
            downloading: false,
            addingDate: Date()
        )
        try await store.add(book: book)
        return book
    }

    public func add(book: Book) async throws -> Book {
        let books = await store.allBooks()
        var mutable = book
        if mutable.id <= 0 || books.contains(where: { $0.id == mutable.id }) {
            mutable.id = (books.map(\.id).max() ?? 0) + 1
        }
        try await store.add(book: mutable)
        return mutable
    }

    public func remove(bookID: Int) async {
        await store.removeBook(id: bookID)
    }

    public func exportStateData() async throws -> Data {
        try await store.exportStateData()
    }

    public func importStateData(_ data: Data) async throws {
        try await store.importStateData(data)
    }
}
