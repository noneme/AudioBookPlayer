import Foundation
import SQLite3

public struct LibraryFilter: Sendable {
    public var author: String?
    public var series: String?
    public var favorite: Bool?
    public var status: BookStatus?
    public var searchQuery: String?

    public init(
        author: String? = nil,
        series: String? = nil,
        favorite: Bool? = nil,
        status: BookStatus? = nil,
        searchQuery: String? = nil
    ) {
        self.author = author
        self.series = series
        self.favorite = favorite
        self.status = status
        self.searchQuery = searchQuery
    }
}

public final class SQLiteRepository: @unchecked Sendable {
    public enum RepoError: Swift.Error {
        case openFailed
        case prepareFailed
        case stepFailed
    }

    private var db: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw RepoError.openFailed
        }
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createSchema() throws {
        let query = """
        CREATE TABLE IF NOT EXISTS books (
            id INTEGER PRIMARY KEY,
            author TEXT NOT NULL,
            name TEXT NOT NULL,
            series_name TEXT NOT NULL,
            number_in_series TEXT NOT NULL,
            description TEXT NOT NULL,
            reader TEXT NOT NULL,
            duration TEXT NOT NULL,
            url TEXT NOT NULL UNIQUE,
            preview TEXT NOT NULL,
            driver TEXT NOT NULL,
            status TEXT NOT NULL,
            stop_item INTEGER NOT NULL,
            stop_time INTEGER NOT NULL,
            favorite INTEGER NOT NULL,
            downloaded INTEGER NOT NULL,
            downloading INTEGER NOT NULL,
            adding_date REAL NOT NULL
        );
        """
        try execute(query)
    }

    private func execute(_ query: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        guard let db else { throw RepoError.openFailed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw RepoError.prepareFailed
        }
        bind?(statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            sqlite3_finalize(statement)
            throw RepoError.stepFailed
        }
        sqlite3_finalize(statement)
    }

    public func upsert(book: Book) throws {
        let query = """
        INSERT INTO books (
            id, author, name, series_name, number_in_series, description, reader,
            duration, url, preview, driver, status, stop_item, stop_time, favorite,
            downloaded, downloading, adding_date
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            author=excluded.author,
            name=excluded.name,
            series_name=excluded.series_name,
            number_in_series=excluded.number_in_series,
            description=excluded.description,
            reader=excluded.reader,
            duration=excluded.duration,
            url=excluded.url,
            preview=excluded.preview,
            driver=excluded.driver,
            status=excluded.status,
            stop_item=excluded.stop_item,
            stop_time=excluded.stop_time,
            favorite=excluded.favorite,
            downloaded=excluded.downloaded,
            downloading=excluded.downloading,
            adding_date=excluded.adding_date;
        """

        try execute(query) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(book.id))
            sqlite3_bind_text(stmt, 2, (book.author as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (book.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (book.seriesName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (book.numberInSeries as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (book.description as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (book.reader as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 8, (book.duration as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 9, (book.url as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 10, (book.preview as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 11, (book.driver as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 12, (book.status.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 13, Int32(book.stopFlag.item))
            sqlite3_bind_int(stmt, 14, Int32(book.stopFlag.time))
            sqlite3_bind_int(stmt, 15, book.favorite ? 1 : 0)
            sqlite3_bind_int(stmt, 16, book.downloaded ? 1 : 0)
            sqlite3_bind_int(stmt, 17, book.downloading ? 1 : 0)
            sqlite3_bind_double(stmt, 18, book.addingDate.timeIntervalSince1970)
        }
    }

    public func remove(bookID: Int) throws {
        try execute("DELETE FROM books WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(bookID))
        }
    }

    public func allBooks(filter: LibraryFilter = LibraryFilter()) throws -> [Book] {
        guard let db else { throw RepoError.openFailed }

        var query = "SELECT id, author, name, series_name, number_in_series, description, reader, duration, url, preview, driver, status, stop_item, stop_time, favorite, downloaded, downloading, adding_date FROM books"
        var clauses: [String] = []

        if filter.author != nil { clauses.append("author = ?") }
        if filter.series != nil { clauses.append("series_name = ?") }
        if filter.favorite != nil { clauses.append("favorite = ?") }
        if filter.status != nil { clauses.append("status = ?") }
        if let q = filter.searchQuery, !q.isEmpty { clauses.append("(lower(author) LIKE ? OR lower(name) LIKE ? OR lower(series_name) LIKE ?)") }

        if !clauses.isEmpty {
            query += " WHERE " + clauses.joined(separator: " AND ")
        }
        query += " ORDER BY adding_date DESC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw RepoError.prepareFailed
        }

        var index: Int32 = 1
        if let author = filter.author {
            sqlite3_bind_text(statement, index, (author as NSString).utf8String, -1, nil)
            index += 1
        }
        if let series = filter.series {
            sqlite3_bind_text(statement, index, (series as NSString).utf8String, -1, nil)
            index += 1
        }
        if let favorite = filter.favorite {
            sqlite3_bind_int(statement, index, favorite ? 1 : 0)
            index += 1
        }
        if let status = filter.status {
            sqlite3_bind_text(statement, index, (status.rawValue as NSString).utf8String, -1, nil)
            index += 1
        }
        if let q = filter.searchQuery?.lowercased(), !q.isEmpty {
            let like = "%\(q)%"
            sqlite3_bind_text(statement, index, (like as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, index + 1, (like as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, index + 2, (like as NSString).utf8String, -1, nil)
        }

        var books: [Book] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            books.append(mapRow(statement: statement))
        }

        sqlite3_finalize(statement)
        return books
    }

    public func setFavorite(bookID: Int, value: Bool) throws {
        try execute("UPDATE books SET favorite = ? WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, value ? 1 : 0)
            sqlite3_bind_int(stmt, 2, Int32(bookID))
        }
    }

    public func setStatus(bookID: Int, status: BookStatus) throws {
        try execute("UPDATE books SET status = ? WHERE id = ?") { stmt in
            sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(bookID))
        }
    }

    public func setStopFlag(bookID: Int, item: Int, time: Int) throws {
        try execute("UPDATE books SET stop_item = ?, stop_time = ? WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(item))
            sqlite3_bind_int(stmt, 2, Int32(time))
            sqlite3_bind_int(stmt, 3, Int32(bookID))
        }
    }

    private func mapRow(statement: OpaquePointer?) -> Book {
        let id = Int(sqlite3_column_int(statement, 0))
        let author = String(cString: sqlite3_column_text(statement, 1))
        let name = String(cString: sqlite3_column_text(statement, 2))
        let seriesName = String(cString: sqlite3_column_text(statement, 3))
        let numberInSeries = String(cString: sqlite3_column_text(statement, 4))
        let description = String(cString: sqlite3_column_text(statement, 5))
        let reader = String(cString: sqlite3_column_text(statement, 6))
        let duration = String(cString: sqlite3_column_text(statement, 7))
        let url = String(cString: sqlite3_column_text(statement, 8))
        let preview = String(cString: sqlite3_column_text(statement, 9))
        let driver = String(cString: sqlite3_column_text(statement, 10))
        let statusRaw = String(cString: sqlite3_column_text(statement, 11))
        let stopItem = Int(sqlite3_column_int(statement, 12))
        let stopTime = Int(sqlite3_column_int(statement, 13))
        let favorite = sqlite3_column_int(statement, 14) == 1
        let downloaded = sqlite3_column_int(statement, 15) == 1
        let downloading = sqlite3_column_int(statement, 16) == 1
        let addingDate = Date(timeIntervalSince1970: sqlite3_column_double(statement, 17))

        return Book(
            id: id,
            author: author,
            name: name,
            seriesName: seriesName,
            numberInSeries: numberInSeries,
            description: description,
            reader: reader,
            duration: duration,
            url: url,
            preview: preview,
            driver: driver,
            items: [],
            status: BookStatus(rawValue: statusRaw) ?? .new,
            stopFlag: StopFlag(item: stopItem, time: stopTime),
            favorite: favorite,
            downloaded: downloaded,
            downloading: downloading,
            addingDate: addingDate
        )
    }
}
