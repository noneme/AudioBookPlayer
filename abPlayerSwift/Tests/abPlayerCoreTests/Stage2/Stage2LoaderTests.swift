import Testing
@testable import abPlayerCore
import Foundation

struct Stage2LoaderTests {
    @Test
    func suitableDriverSelectionByURL() {
        let registry = DriverRegistry.default()

        let akniga = DriverLookup.suitableDriver(for: "https://akniga.org/some-book", in: registry.drivers)
        #expect(akniga?.name == "AKniga")

        let kniga = DriverLookup.suitableDriver(for: "https://knigavuhe.org/book/test", in: registry.drivers)
        #expect(kniga?.name == "KnigaVUhe")
    }

    @Test
    func loaderSearchUpdatesOffsets() async throws {
        let loader = DefaultLoaderService(registry: .default())
        let initialState: [String: (offset: Int, canLoadNext: Bool)] = [
            "AKniga": (0, true),
            "KnigaVUhe": (0, true)
        ]

        let result = try await loader.searchBooks(
            query: "война",
            requiredDrivers: ["AKniga", "KnigaVUhe"],
            searchState: initialState,
            limit: 10
        )

        #expect(!result.results.isEmpty)
        #expect((result.searchState["AKniga"]?.offset ?? 0) >= 1)
    }

    @Test
    func jsDecryptorResourceIsLoadable() throws {
        let decryptor = AKnigaDecryptor()
        let output = try decryptor.decrypt(hres: "invalid", securityKey: "demo")
        #expect(output == nil)
    }

    @Test
    func commonCryptoDecryptorHandlesInvalidPayload() throws {
        let decryptor = AKnigaCommonCryptoDecryptor()
        let output = try decryptor.decrypt(hres: "invalid", securityKey: "demo")
        #expect(output == nil)
    }

    @Test
    func downloadManagerTerminatesTask() async {
        let manager = DownloadManager()
        let task = DownloadTaskInfo(
            bid: 101,
            title: "Demo",
            destinationRoot: NSTemporaryDirectory(),
            book: Book(id: 101, author: "A", name: "B", url: "https://example.org", items: [BookItem(fileURL: "https://example.org/a.mp3", fileIndex: 0, title: "C", startTime: 0, endTime: 1)]),
            urls: ["https://example.org/a.mp3"],
            kind: .mp3,
            descriptionLanguage: .en
        )

        let recorder = ProgressRecorder()
        await manager.enqueue(task) { progress in
            Task { await recorder.append(progress) }
        }

        await manager.terminate(bid: 101) { progress in
            Task { await recorder.append(progress) }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let last = await recorder.lastStatus()
        #expect(last == .terminated)
    }
}

actor ProgressRecorder {
    private var items: [DownloadProgress] = []

    func append(_ value: DownloadProgress) {
        items.append(value)
    }

    func lastStatus() -> DownloadEntry.Status? {
        items.last?.status
    }
}
