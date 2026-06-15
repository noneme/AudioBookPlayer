import Foundation

public actor InMemoryStore {
    public struct PersistedState: Codable, Sendable {
        var books: [Book]
        var downloads: [DownloadEntry]

        public init(books: [Book], downloads: [DownloadEntry]) {
            self.books = books
            self.downloads = downloads
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private var books: [Book]
    private var downloads: [DownloadEntry]
    private let persistenceURL: URL?
    private let fm: FileManager

    public init(seedBooks: [Book] = [], seedDownloads: [DownloadEntry] = [], persistenceURL: URL? = nil, fileManager: FileManager = .default) {
        self.persistenceURL = persistenceURL
        self.fm = fileManager

        if let persistenceURL,
           let recovered = Self.loadState(from: persistenceURL)
        {
            let normalized = Self.normalizeRecoveredState(recovered)
            self.books = normalized.books
            self.downloads = normalized.downloads
        } else {
            self.books = seedBooks
            self.downloads = seedDownloads
        }
    }

    public func allBooks() -> [Book] {
        books
    }

    public func add(book: Book) throws {
        if books.contains(where: { $0.url == book.url }) {
            throw CloneError.alreadyExists
        }
        books.append(book)
        persistSnapshot()
    }

    public func update(book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else {
            return
        }
        books[index] = book
        persistSnapshot()
    }

    public func removeBook(id: Int) {
        books.removeAll { $0.id == id }
        downloads.removeAll { $0.bid == id }
        persistSnapshot()
    }

    public func allDownloads() -> [DownloadEntry] {
        downloads
    }

    public func setDownloads(_ items: [DownloadEntry]) {
        downloads = items
        persistSnapshot()
    }

    public func exportStateData() throws -> Data {
        let state = PersistedState(books: books, downloads: downloads)
        return try Self.encoder.encode(state)
    }

    public func importStateData(_ data: Data) throws {
        let decoded = try Self.decoder.decode(PersistedState.self, from: data)
        let normalized = Self.normalizeRecoveredState(decoded)
        books = normalized.books
        downloads = normalized.downloads
        persistSnapshot()
    }

    private func persistSnapshot() {
        guard let persistenceURL else { return }

        let state = PersistedState(books: books, downloads: downloads)
        do {
            let data = try Self.encoder.encode(state)
            try fm.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            // Ignore persistence errors to keep runtime behavior functional.
        }
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(PersistedState.self, from: data)
    }

    private static func normalizeRecoveredState(_ state: PersistedState) -> PersistedState {
        let activeStatuses: Set<DownloadEntry.Status> = [.waiting, .preparing, .downloading, .finishing, .terminating]

        let normalizedDownloads = state.downloads.map { entry -> DownloadEntry in
            guard activeStatuses.contains(entry.status) else {
                return entry
            }
            var copy = entry
            copy.status = .terminated
            copy.stage = "Interrupted"
            if copy.errorMessage.isEmpty {
                copy.errorMessage = "Interrupted by app restart"
            }
            return copy
        }

        let normalizedBooks = state.books.map { book -> Book in
            var copy = book
            if copy.downloading {
                copy.downloading = false
            }
            return copy
        }

        return PersistedState(books: normalizedBooks, downloads: normalizedDownloads)
    }
}

public enum DemoData {
    public static let drivers: [DriverInfo] = [
        DriverInfo(name: "KnigaVUhe", licensed: false, authed: true, url: "https://knigavuhe.org"),
        DriverInfo(name: "AKniga", licensed: false, authed: true, url: "https://akniga.org"),
        DriverInfo(name: "Izibuk", licensed: false, authed: true, url: "https://izib.uk"),
        DriverInfo(name: "Yakniga", licensed: false, authed: true, url: "https://yakniga.org"),
        DriverInfo(name: "LibriVox", licensed: false, authed: true, url: "https://archive.org"),
        DriverInfo(name: "Bookmate", licensed: true, authed: false, url: "https://books.yandex.ru")
    ]

    public static let books: [Book] = [
        Book(
            id: 1,
            author: "Лев Толстой",
            name: "Война и мир",
            seriesName: "Русская классика",
            numberInSeries: "1",
            description: "Роман-эпопея о русском обществе в эпоху войн против Наполеона.",
            reader: "Александр Клюквин",
            duration: "56:40:00",
            url: "https://akniga.org/tolstoy-lev-voyna-i-mir",
            preview: "",
            driver: "AKniga",
            items: [BookItem(fileURL: "", fileIndex: 0, title: "Том 1", startTime: 0, endTime: 3600)],
            status: .started,
            stopFlag: StopFlag(item: 0, time: 900),
            favorite: true,
            downloaded: true,
            downloading: false,
            addingDate: Date(timeIntervalSince1970: 1_710_000_000)
        ),
        Book(
            id: 2,
            author: "Артур Конан Дойл",
            name: "Этюд в багровых тонах",
            seriesName: "Шерлок Холмс",
            numberInSeries: "1",
            description: "Первое дело Шерлока Холмса и доктора Ватсона.",
            reader: "Олег Булдаков",
            duration: "07:10:00",
            url: "https://knigavuhe.org/book/ehtjud-v-bagrovykh-tonakh/",
            preview: "",
            driver: "KnigaVUhe",
            status: .new,
            favorite: false,
            downloaded: false,
            downloading: false,
            addingDate: Date(timeIntervalSince1970: 1_720_000_000)
        )
    ]

    public static let searchResults: [BookPreview] = [
        BookPreview(
            author: "Лев Толстой",
            name: "Война и мир",
            seriesName: "Русская классика",
            numberInSeries: "1",
            reader: "Александр Клюквин",
            duration: "56:40:00",
            url: "https://akniga.org/tolstoy-lev-voyna-i-mir",
            driver: "AKniga"
        ),
        BookPreview(
            author: "Артур Конан Дойл",
            name: "Этюд в багровых тонах",
            seriesName: "Шерлок Холмс",
            numberInSeries: "1",
            reader: "Олег Булдаков",
            duration: "07:10:00",
            url: "https://knigavuhe.org/book/ehtjud-v-bagrovykh-tonakh/",
            driver: "KnigaVUhe"
        )
    ]
}
