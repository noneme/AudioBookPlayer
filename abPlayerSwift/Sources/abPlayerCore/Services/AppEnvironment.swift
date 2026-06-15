import Foundation

public struct AppEnvironment: Sendable {
    public let searchService: SearchService
    public let libraryService: LibraryService
    public let downloadService: DownloadQueueService
    public let bookDetailsService: BookDetailsService
    public let settingsService: SettingsService
    public let drivers: [DriverInfo]

    public init(
        searchService: SearchService,
        libraryService: LibraryService,
        downloadService: DownloadQueueService,
        bookDetailsService: BookDetailsService,
        settingsService: SettingsService,
        drivers: [DriverInfo]
    ) {
        self.searchService = searchService
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.bookDetailsService = bookDetailsService
        self.settingsService = settingsService
        self.drivers = drivers
    }

    public static func `default`() -> AppEnvironment {
        let store = InMemoryStore()
        let settingsService = UserDefaultsSettingsService()
        return AppEnvironment(
            searchService: MockSearchService(),
            libraryService: DefaultLibraryService(store: store),
            downloadService: RealDownloadQueueService(
                store: store,
                settingsService: settingsService,
                manager: DownloadManager()
            ),
            bookDetailsService: DefaultBookDetailsService(),
            settingsService: settingsService,
            drivers: DemoData.drivers
        )
    }

    public static func production() -> AppEnvironment {
        let store = InMemoryStore(persistenceURL: persistenceURL())
        let registry = DriverRegistry.default()
        let settingsService = UserDefaultsSettingsService()
        let drivers = registry.drivers.map {
            DriverInfo(
                name: $0.name,
                licensed: $0.isLicensed,
                authed: $0.isAuthenticated,
                url: $0.siteURL
            )
        }
        return AppEnvironment(
            searchService: LiveSearchService(loader: DefaultLoaderService(registry: registry)),
            libraryService: DefaultLibraryService(store: store),
            downloadService: RealDownloadQueueService(
                store: store,
                settingsService: settingsService,
                manager: DownloadManager()
            ),
            bookDetailsService: DefaultBookDetailsService(loader: DefaultLoaderService(registry: registry)),
            settingsService: settingsService,
            drivers: drivers
        )
    }

    public static func sqlite(path sqlitePath: String) async throws -> AppEnvironment {
        let repository = try SQLiteRepository(path: sqlitePath)
        let service = SQLiteLibraryService(repository: repository)

        for book in DemoData.books {
            try repository.upsert(book: book)
        }

        let store = InMemoryStore()
        return AppEnvironment(
            searchService: MockSearchService(),
            libraryService: service,
            downloadService: RealDownloadQueueService(
                store: store,
                settingsService: UserDefaultsSettingsService(),
                manager: DownloadManager()
            ),
            bookDetailsService: DefaultBookDetailsService(),
            settingsService: UserDefaultsSettingsService(),
            drivers: DemoData.drivers
        )
    }

    private static func persistenceURL() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())

        return support
            .appendingPathComponent("abPlayerSwift", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }
}
