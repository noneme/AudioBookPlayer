import Foundation

public protocol DownloadQueueService: Sendable {
    func allDownloads() async -> [DownloadEntry]
    func enqueue(book: Book) async
    func terminate(bid: Int) async
    func removeDownloaded(bid: Int) async throws
    func setBookState(_ bookID: Int, downloading: Bool, downloaded: Bool) async
    func isActive(bid: Int) async -> Bool
}

private func taskKind(for book: Book) -> DownloadTaskInfo.Kind {
    if book.driver == "AKniga" {
        return .mergedM3U8
    }
    let urls = Set(book.items.map { $0.fileURL })
    if urls.count == 1, let only = urls.first, only.contains(".m3u8") {
        return book.items.count > 1 ? .mergedM3U8 : .m3u8
    }
    if book.items.allSatisfy({ $0.fileURL.contains(".m3u8") }) {
        return .m3u8
    }
    return .mp3
}

private func descriptionLanguage(for appLanguage: AppLanguageMode) -> DownloadTaskInfo.DescriptionLanguage {
    switch appLanguage {
    case .en:
        return .en
    case .ru:
        return .ru
    case .system:
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("ru") ? .ru : .en
    }
}

public actor RealDownloadQueueService: DownloadQueueService {
    private let store: InMemoryStore
    private let settingsService: SettingsService
    private let manager: DownloadManager

    public init(store: InMemoryStore, settingsService: SettingsService, manager: DownloadManager = DownloadManager()) {
        self.store = store
        self.settingsService = settingsService
        self.manager = manager
    }

    public func allDownloads() async -> [DownloadEntry] {
        await store.allDownloads()
    }

    public func isActive(bid: Int) async -> Bool {
        if await manager.isQueuedOrActive(bid: bid) {
            return true
        }
        let current = await store.allDownloads()
        guard let item = current.first(where: { $0.bid == bid }) else {
            return false
        }
        return item.status == .waiting || item.status == .preparing || item.status == .downloading || item.status == .finishing
    }

    public func enqueue(book: Book) async {
        var current = await store.allDownloads()
        if await isActive(bid: book.id) {
            return
        }
        await manager.clearTerminationFlag(bid: book.id)

        if let existingIndex = current.firstIndex(where: { $0.bid == book.id }) {
            if current[existingIndex].status == .finished {
                return
            }
            current.remove(at: existingIndex)
        }

        current.append(DownloadEntry(
            bid: book.id,
            title: book.name,
            status: .waiting,
            totalSize: "",
            doneSize: "",
            progressPercent: 0,
            stage: "Queued",
            errorMessage: ""
        ))
        await store.setDownloads(current)
        await setBookState(book.id, downloading: true, downloaded: false)

        let destination = await settingsService.downloadDirectoryPath()
        let appLanguage = await settingsService.appLanguage()
        let task = DownloadTaskInfo(
            bid: book.id,
            title: book.name,
            destinationRoot: destination,
            book: book,
            urls: book.items.map { $0.fileURL },
            kind: taskKind(for: book),
            descriptionLanguage: descriptionLanguage(for: appLanguage)
        )

        await manager.enqueue(task) { [weak self] progress in
            guard let self else { return }
            Task {
                await self.applyProgress(progress)
            }
        }
    }

    public func terminate(bid: Int) async {
        await manager.terminate(bid: bid) { [weak self] progress in
            guard let self else { return }
            Task {
                await self.applyProgress(progress)
            }
        }
    }

    public func removeDownloaded(bid: Int) async throws {
        var current = await store.allDownloads()
        guard let dIndex = current.firstIndex(where: { $0.bid == bid }) else {
            throw CloneError.notFound
        }

        let item = current[dIndex]
        guard item.status == .finished else {
            throw CloneError.connectionIssue("Download is not finished")
        }

        let books = await store.allBooks()
        guard let book = books.first(where: { $0.id == bid }) else {
            throw CloneError.notFound
        }

        let destination = DownloadIO.destinationDirectory(for: book, rootPath: await settingsService.downloadDirectoryPath())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        await setBookState(bid, downloading: false, downloaded: false)
        current.remove(at: dIndex)
        await store.setDownloads(current)
    }

    public func setBookState(_ bookID: Int, downloading: Bool, downloaded: Bool) async {
        var books = await store.allBooks()
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].downloading = downloading
        books[index].downloaded = downloaded
        await store.update(book: books[index])
    }

    private func statusRank(_ status: DownloadEntry.Status) -> Int {
        switch status {
        case .waiting:
            return 0
        case .preparing:
            return 1
        case .downloading:
            return 2
        case .finishing:
            return 3
        case .finished, .terminated:
            return 4
        case .terminating:
            return 5
        }
    }

    private func shouldIgnoreProgress(existing: DownloadEntry, incoming: DownloadProgress) -> Bool {
        // Once terminal state is persisted, ignore any delayed downloader callbacks.
        if existing.status == .finished || existing.status == .terminated {
            return true
        }

        if incoming.status != .terminated {
            if statusRank(incoming.status) < statusRank(existing.status) {
                return true
            }
            if incoming.status == existing.status,
               incoming.percent + 0.001 < existing.progressPercent,
               incoming.errorMessage.isEmpty
            {
                return true
            }
        }

        return false
    }

    private func applyProgress(_ progress: DownloadProgress) async {
        var current = await store.allDownloads()
        guard let index = current.firstIndex(where: { $0.bid == progress.bid }) else { return }

        let existing = current[index]
        if shouldIgnoreProgress(existing: existing, incoming: progress) {
            return
        }

        current[index].status = progress.status
        current[index].progressPercent = max(existing.progressPercent, progress.percent)
        current[index].doneSize = progress.doneSize
        current[index].totalSize = progress.totalSize
        current[index].stage = progress.stage
        if !progress.errorMessage.isEmpty {
            current[index].errorMessage = progress.errorMessage
        } else if progress.status == .finished {
            current[index].errorMessage = ""
        }
        await store.setDownloads(current)

        if progress.status == .finished {
            await setBookState(progress.bid, downloading: false, downloaded: true)
        } else if progress.status == .terminated {
            await setBookState(progress.bid, downloading: false, downloaded: false)
        }
    }
}

public actor MockDownloadQueueService: DownloadQueueService {
    private let store: InMemoryStore

    public init(store: InMemoryStore) {
        self.store = store
    }

    public func allDownloads() async -> [DownloadEntry] {
        await store.allDownloads()
    }

    public func enqueue(book: Book) async {
        var current = await store.allDownloads()
        guard !current.contains(where: { $0.bid == book.id }) else { return }
        current.append(DownloadEntry(
            bid: book.id,
            title: book.name,
            status: .waiting,
            totalSize: "",
            doneSize: "",
            progressPercent: 0,
            stage: "Queued",
            errorMessage: ""
        ))
        await store.setDownloads(current)
    }

    public func terminate(bid: Int) async {
        var current = await store.allDownloads()
        guard let index = current.firstIndex(where: { $0.bid == bid }) else { return }
        current[index].status = .terminated
        await store.setDownloads(current)
    }

    public func removeDownloaded(bid: Int) async throws {
        var current = await store.allDownloads()
        guard let index = current.firstIndex(where: { $0.bid == bid }) else {
            throw CloneError.notFound
        }
        current.remove(at: index)
        await store.setDownloads(current)
    }

    public func setBookState(_ bookID: Int, downloading: Bool, downloaded: Bool) async {}

    public func isActive(bid: Int) async -> Bool {
        false
    }
}
