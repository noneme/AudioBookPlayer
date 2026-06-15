import Foundation

@MainActor
public final class AppStateStore: ObservableObject {
    public struct LocalAudioTrack: Sendable, Equatable, Identifiable {
        public let itemIndex: Int
        public let title: String
        public let url: URL

        public var id: Int { itemIndex }

        public init(itemIndex: Int, title: String, url: URL) {
            self.itemIndex = itemIndex
            self.title = title
            self.url = url
        }
    }

    @Published public var currentPage: AppPage = .library
    @Published public var selectedLibrarySection: LibrarySection = .all
    @Published public var selectedPlayerBookID: Int?

    @Published public var books: [Book] = []
    @Published public var searchResults: [BookPreview] = []
    @Published public var downloads: [DownloadEntry] = []

    @Published public var libraryQuery: String = ""
    @Published public var searchQuery: String = ""
    @Published public var requiredDrivers: [String] = []
    @Published public var availableDrivers: [DriverInfo] = []
    @Published public var downloadDirectoryPath: String = ""
    @Published public var appearanceMode: AppAppearanceMode = .system
    @Published public var appLanguage: AppLanguageMode = .system
    @Published public var bookmateAuthToken: String = ""

    @Published public var isSearching: Bool = false
    @Published public var errorMessage: String?

    private let environment: AppEnvironment
    private let settingsService: SettingsService
    private let registryBuilder: @Sendable (String) -> DriverRegistry
    private var searchOffsets: [String: Int] = [:]
    private var canLoadNextByDriver: [String: Bool] = [:]
    private var lastSearchTaskID: UUID?
    private var downloadWatchTasks: [Int: Task<Void, Never>] = [:]

    private var liveLoader: DefaultLoaderService?
    private var liveSearchService: LiveSearchService?
    private var liveBookDetailsService: DefaultBookDetailsService?

    public init(
        environment: AppEnvironment = .default(),
        settingsService: SettingsService? = nil,
        registryBuilder: @escaping @Sendable (String) -> DriverRegistry = { DriverRegistry(bookmateAuthToken: $0) }
    ) {
        self.environment = environment
        self.settingsService = settingsService ?? environment.settingsService
        self.registryBuilder = registryBuilder
        self.availableDrivers = environment.drivers
        self.requiredDrivers = environment.drivers.filter(\.authed).map(\.name)
        for driver in requiredDrivers {
            searchOffsets[driver] = 0
            canLoadNextByDriver[driver] = true
        }
    }

    public func startup() {
        Task {
            await loadLibrary()
            await loadDownloads()
            await loadSettings()
            await reloadDriversFromSettings()
        }
    }

    public func open(page: AppPage) {
        currentPage = page
    }

    public func selectedPlayerBook() -> Book? {
        guard let selectedPlayerBookID else { return nil }
        return books.first(where: { $0.id == selectedPlayerBookID })
    }

    public func loadLibrary() async {
        let all = await environment.libraryService.allBooks()
        books = all.sorted { $0.addingDate > $1.addingDate }
    }

    public func loadDownloads() async {
        downloads = await environment.downloadService.allDownloads()
    }

    public func loadSettings() async {
        downloadDirectoryPath = await environment.settingsService.downloadDirectoryPath()
        appearanceMode = await environment.settingsService.appearanceMode()
        appLanguage = await environment.settingsService.appLanguage()
        bookmateAuthToken = await settingsService.bookmateAuthToken()
    }

    public func setDownloadDirectoryPath(_ path: String) async {
        do {
            try await environment.settingsService.setDownloadDirectoryPath(path)
            downloadDirectoryPath = await environment.settingsService.downloadDirectoryPath()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setAppearanceMode(_ mode: AppAppearanceMode) async {
        await environment.settingsService.setAppearanceMode(mode)
        appearanceMode = await environment.settingsService.appearanceMode()
    }

    public func setAppLanguage(_ mode: AppLanguageMode) async {
        await environment.settingsService.setAppLanguage(mode)
        appLanguage = await environment.settingsService.appLanguage()
    }

    public func setBookmateAuthToken(_ token: String) async {
        await settingsService.setBookmateAuthToken(token)
        bookmateAuthToken = await settingsService.bookmateAuthToken()
        await reloadDriversFromSettings()
    }

    public func clearBookmateAuthToken() async {
        await settingsService.clearBookmateAuthToken()
        bookmateAuthToken = await settingsService.bookmateAuthToken()
        await reloadDriversFromSettings()
    }

    public func isBookmateAuthenticated() -> Bool {
        !bookmateAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func canDownload(book: Book) -> Bool {
        if book.downloaded || book.downloading {
            return true
        }
        if book.driver == "Bookmate" {
            return isBookmateAuthenticated()
        }
        return true
    }

    public func exportLibraryState(to url: URL) async {
        do {
            let data = try await environment.libraryService.exportStateData()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func importLibraryState(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            try await environment.libraryService.importStateData(data)
            await loadDownloads()
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func filteredBooks() -> [Book] {
        let bySection: [Book]
        switch selectedLibrarySection {
        case .all:
            bySection = books
        case .favorites:
            bySection = books.filter { $0.favorite }
        case .downloaded:
            bySection = books.filter { $0.downloaded }
        case .new:
            bySection = books.filter { $0.status == .new }
        case .started:
            bySection = books.filter { $0.status == .started }
        case .finished:
            bySection = books.filter { $0.status == .finished }
        }

        let trimmed = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bySection }

        let tokens = trimmed.lowercased().split(separator: " ").map(String.init)
        return bySection.filter { book in
            let haystack = [book.author, book.name, book.seriesName].joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    public func toggleDriver(_ name: String) {
        guard let info = availableDrivers.first(where: { $0.name == name }), info.authed else {
            return
        }
        if requiredDrivers.count == 1, requiredDrivers.contains(name) {
            return
        }
        if requiredDrivers.contains(name) {
            requiredDrivers.removeAll { $0 == name }
        } else {
            requiredDrivers.append(name)
        }
    }

    public func runSearch(reset: Bool = true) async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            searchResults = []
            return
        }

        let taskID = UUID()
        lastSearchTaskID = taskID

        if reset {
            searchOffsets = Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, 0) })
            canLoadNextByDriver = Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, true) })
        }

        isSearching = true
        defer { isSearching = false }

        do {
            if let liveSearchService {
                let effectiveDrivers = requiredDrivers.filter { canLoadNextByDriver[$0, default: true] }
                if effectiveDrivers.isEmpty {
                    searchResults = []
                    return
                }

                let (results, offsets, canLoadNext) = try await liveSearchService.search(
                    query: trimmed,
                    requiredDrivers: effectiveDrivers,
                    offsetByDriver: searchOffsets
                )

                guard lastSearchTaskID == taskID else {
                    return
                }

                searchOffsets.merge(offsets) { _, rhs in rhs }
                canLoadNextByDriver.merge(canLoadNext) { _, rhs in rhs }
                if reset {
                    searchResults = results
                } else {
                    searchResults.append(contentsOf: results)
                }
                return
            }

            let effectiveDrivers = requiredDrivers.filter { canLoadNextByDriver[$0, default: true] }
            if effectiveDrivers.isEmpty {
                searchResults = []
                return
            }
            let (results, offsets, canLoadNext) = try await environment.searchService.search(
                query: trimmed,
                requiredDrivers: effectiveDrivers,
                offsetByDriver: searchOffsets
            )

            guard lastSearchTaskID == taskID else {
                return
            }

            searchOffsets.merge(offsets) { _, rhs in rhs }
            canLoadNextByDriver.merge(canLoadNext) { _, rhs in rhs }
            if reset {
                searchResults = results
            } else {
                searchResults.append(contentsOf: results)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func canLoadMoreSearchResults() -> Bool {
        requiredDrivers.contains { canLoadNextByDriver[$0, default: false] }
    }

    public func loadMoreSearchIfNeeded(currentItem item: BookPreview) async {
        guard !isSearching else { return }
        guard canLoadMoreSearchResults() else { return }
        guard let last = searchResults.last, last.id == item.id else { return }
        await runSearch(reset: false)
    }

    public func addBook(_ preview: BookPreview) async {
        do {
            let fullBook: Book
            if let liveBookDetailsService {
                fullBook = try await liveBookDetailsService.fetchBook(url: preview.url)
            } else {
                fullBook = try await environment.bookDetailsService.fetchBook(url: preview.url)
            }
            _ = try await environment.libraryService.add(book: fullBook)
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func toggleFavorite(bookID: Int) async {
        _ = await environment.libraryService.toggleFavorite(bookID: bookID)
        await loadLibrary()
    }

    public func queueDownload(book: Book) async {
        guard canDownload(book: book) else {
            errorMessage = "Bookmate authorization required"
            return
        }

        if await environment.downloadService.isActive(bid: book.id) {
            return
        }

        var bookToDownload = book
        if book.driver == "AKniga" {
            do {
                let fetched: Book
                if let liveBookDetailsService {
                    fetched = try await liveBookDetailsService.fetchBook(url: book.url)
                } else {
                    fetched = try await environment.bookDetailsService.fetchBook(url: book.url)
                }
                var fresh = fetched
                fresh.id = book.id
                fresh.favorite = book.favorite
                fresh.status = book.status
                fresh.stopFlag = book.stopFlag
                fresh.downloaded = book.downloaded
                fresh.downloading = book.downloading
                fresh.addingDate = book.addingDate
                bookToDownload = fresh
            } catch {
                errorMessage = "AKniga refresh failed before download: \(error.localizedDescription)"
                return
            }
        }

        await environment.downloadService.enqueue(book: bookToDownload)
        await loadDownloads()
        await loadLibrary()
        watchDownloadCompletion(bid: book.id)
    }

    public func openBookPlayer(bookID: Int) {
        guard let book = books.first(where: { $0.id == bookID }), book.downloaded else {
            return
        }
        selectedPlayerBookID = bookID
        currentPage = .bookPlayer
    }

    public func closeBookPlayer() {
        selectedPlayerBookID = nil
        currentPage = .library
    }

    public func localAudioTracks(for book: Book) async -> [LocalAudioTrack] {
        guard book.downloaded else { return [] }

        let destination = DownloadIO.destinationDirectory(
            for: book,
            rootPath: await environment.settingsService.downloadDirectoryPath()
        )
        let fm = FileManager.default
        let orderedItems = book.items.sorted { $0.fileIndex < $1.fileIndex }

        var resolved: [LocalAudioTrack] = []
        for (index, item) in orderedItems.enumerated() {
            let mp3 = destination.appendingPathComponent(
                DownloadIO.itemFilename(index: index, title: item.title, ext: "mp3")
            )
            if fm.fileExists(atPath: mp3.path) {
                resolved.append(LocalAudioTrack(itemIndex: index, title: item.title, url: mp3))
                continue
            }

            let m4a = destination.appendingPathComponent(
                DownloadIO.itemFilename(index: index, title: item.title, ext: "m4a")
            )
            if fm.fileExists(atPath: m4a.path) {
                resolved.append(LocalAudioTrack(itemIndex: index, title: item.title, url: m4a))
            }
        }
        return resolved
    }

    public func updateListeningProgress(bookID: Int, item: Int, time: Int) async {
        await environment.libraryService.setStopFlag(bookID: bookID, item: item, time: time)

        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let maxItem = max(0, books[index].items.count - 1)
        books[index].stopFlag = StopFlag(item: min(max(0, item), maxItem), time: max(0, time))
    }

    public func updateBookStatus(bookID: Int, status: BookStatus) async {
        await environment.libraryService.setStatus(bookID: bookID, status: status)
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].status = status
    }

    public func terminateDownload(bid: Int) async {
        downloadWatchTasks[bid]?.cancel()
        downloadWatchTasks.removeValue(forKey: bid)
        await environment.downloadService.terminate(bid: bid)
        await loadDownloads()
        await loadLibrary()
    }

    public func removeDownloaded(bid: Int) async {
        downloadWatchTasks[bid]?.cancel()
        downloadWatchTasks.removeValue(forKey: bid)
        do {
            try await environment.downloadService.removeDownloaded(bid: bid)
            if selectedPlayerBookID == bid {
                selectedPlayerBookID = nil
                currentPage = .library
            }
            await loadDownloads()
            await loadLibrary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteBookFromLibrary(bookID: Int) async {
        guard let book = books.first(where: { $0.id == bookID }) else {
            errorMessage = CloneError.notFound.localizedDescription
            return
        }

        if book.downloaded {
            do {
                try await environment.downloadService.removeDownloaded(bid: bookID)
            } catch {
                // Fallback: in case downloads entry is missing, remove files directly.
                let destination = DownloadIO.destinationDirectory(
                    for: book,
                    rootPath: await environment.settingsService.downloadDirectoryPath()
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        try FileManager.default.removeItem(at: destination)
                    } catch {
                        errorMessage = error.localizedDescription
                        return
                    }
                }
            }
        }

        await environment.libraryService.remove(bookID: bookID)

        if selectedPlayerBookID == bookID {
            selectedPlayerBookID = nil
            currentPage = .library
        }

        await loadDownloads()
        await loadLibrary()
    }

    private func watchDownloadCompletion(bid: Int) {
        guard downloadWatchTasks[bid] == nil else { return }

        downloadWatchTasks[bid] = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.downloadWatchTasks.removeValue(forKey: bid)
                }
            }

            while !Task.isCancelled {
                let active = await self.environment.downloadService.isActive(bid: bid)
                if !active {
                    await self.loadDownloads()
                    await self.loadLibrary()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func reloadDriversFromSettings() async {
        let token = await settingsService.bookmateAuthToken()
        let registry = registryBuilder(token)

        let driversInfo = registry.drivers.map {
            DriverInfo(name: $0.name, licensed: $0.isLicensed, authed: $0.isAuthenticated, url: $0.siteURL)
        }

        availableDrivers = driversInfo

        let allowed = Set(driversInfo.filter(\.authed).map(\.name))
        requiredDrivers = requiredDrivers.filter { allowed.contains($0) }
        if requiredDrivers.isEmpty {
            requiredDrivers = driversInfo.filter(\.authed).map(\.name)
        }

        searchOffsets = Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, 0) })
        canLoadNextByDriver = Dictionary(uniqueKeysWithValues: requiredDrivers.map { ($0, true) })

        let loader = DefaultLoaderService(registry: registry)
        liveLoader = loader
        liveSearchService = LiveSearchService(loader: loader)
        liveBookDetailsService = DefaultBookDetailsService(loader: loader)
    }
}
