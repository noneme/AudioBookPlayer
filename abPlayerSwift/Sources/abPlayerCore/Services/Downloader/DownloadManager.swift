import Foundation

public actor DownloadManager {
    public static let maxParallel = 5

    private var queue: [DownloadTaskInfo] = []
    private var active: [Int: Task<Void, Never>] = [:]
    private var terminated: Set<Int> = []

    public init() {}

    private static func makeProgress(
        bid: Int,
        status: DownloadEntry.Status,
        percent: Double,
        doneSize: String,
        totalSize: String,
        stage: String,
        errorMessage: String = ""
    ) -> DownloadProgress {
        DownloadProgress(
            bid: bid,
            status: status,
            percent: percent,
            doneSize: doneSize,
            totalSize: totalSize,
            stage: stage,
            errorMessage: errorMessage
        )
    }

    public func isQueuedOrActive(bid: Int) -> Bool {
        active[bid] != nil || queue.contains(where: { $0.bid == bid })
    }

    public func clearTerminationFlag(bid: Int) {
        terminated.remove(bid)
    }

    public func enqueue(_ task: DownloadTaskInfo, onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        if active[task.bid] != nil || queue.contains(where: { $0.bid == task.bid }) {
            return
        }
        queue.append(task)
        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .waiting,
            percent: 0,
            doneSize: "0 MB",
            totalSize: "0 MB",
            stage: "Queued"
        ))
        runNext(onProgress: onProgress)
    }

    public func terminate(bid: Int, onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        terminated.insert(bid)
        queue.removeAll { $0.bid == bid }
        if let task = active.removeValue(forKey: bid) {
            task.cancel()
        }
        onProgress(Self.makeProgress(
            bid: bid,
            status: .terminated,
            percent: 100,
            doneSize: "-",
            totalSize: "-",
            stage: "Cancelled",
            errorMessage: "Cancelled by user"
        ))
        runNext(onProgress: onProgress)
    }

    private func runNext(onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        while active.count < Self.maxParallel, !queue.isEmpty {
            let item = queue.removeFirst()
            let handle = Task {
                await self.execute(item, onProgress: onProgress)
            }
            active[item.bid] = handle
        }
    }

    private func execute(_ item: DownloadTaskInfo, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async {
        if terminated.contains(item.bid) {
            active[item.bid] = nil
            runNext(onProgress: onProgress)
            return
        }

        do {
            try await executeRealDownload(item, onProgress: onProgress)
        } catch {
            let message = String(describing: error)
            onProgress(Self.makeProgress(
                bid: item.bid,
                status: .terminated,
                percent: 100,
                doneSize: "-",
                totalSize: "-",
                stage: "Failed",
                errorMessage: message
            ))
        }

        active[item.bid] = nil
        runNext(onProgress: onProgress)
    }

    private func executeRealDownload(_ task: DownloadTaskInfo, onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let book = task.book
        let destination = DownloadIO.destinationDirectory(for: book, rootPath: task.destinationRoot)
        let cancellationFlag = DownloadIO.CancellationFlag()
        await cancellationFlag.set(terminated.contains(task.bid) || Task.isCancelled)

        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .preparing,
            percent: 0,
            doneSize: "0 MB",
            totalSize: "0 MB",
            stage: "Preparing destination: \(destination.path)"
        ))

        try DownloadIO.ensureDirectoryPath(destination)

        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .preparing,
            percent: 0,
            doneSize: "0 MB",
            totalSize: "0 MB",
            stage: "Preparing destination"
        ))

        switch task.kind {
        case .mp3:
            try await downloadMP3Book(task: task, destination: destination, onProgress: onProgress, cancellationFlag: cancellationFlag)
        case .m3u8:
            try await downloadM3U8Book(task: task, destination: destination, onProgress: onProgress, cancellationFlag: cancellationFlag)
        case .mergedM3U8:
            try await downloadMergedM3U8Book(task: task, destination: destination, onProgress: onProgress, cancellationFlag: cancellationFlag)
        }

        try DownloadIO.writeDescriptionFile(
            for: book,
            language: task.descriptionLanguage,
            in: destination
        )
        await DownloadIO.saveCoverIfAvailable(for: book, in: destination)

        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .finishing,
            percent: 100,
            doneSize: "done",
            totalSize: "done",
            stage: "Finishing"
        ))
        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .finished,
            percent: 100,
            doneSize: "done",
            totalSize: "done",
            stage: "Completed"
        ))
    }

    private func downloadMP3Book(
        task: DownloadTaskInfo,
        destination: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        cancellationFlag: DownloadIO.CancellationFlag
    ) async throws {
        let items = task.book.items.sorted { $0.fileIndex < $1.fileIndex }
        let sourceURLs = items.compactMap { URL(string: $0.fileURL) }
        let expectedSizes = await withTaskGroup(of: Int64?.self) { group -> [Int64] in
            for source in sourceURLs {
                group.addTask { await DownloadIO.contentLength(source) }
            }
            var values: [Int64] = []
            for await value in group {
                values.append(value ?? 0)
            }
            return values
        }
        let totalBytes = max(1, expectedSizes.reduce(0, +))
        var doneBytes: Int64 = 0

        onProgress(Self.makeProgress(
            bid: task.bid,
            status: .downloading,
            percent: 0,
            doneSize: DownloadIO.formatMB(doneBytes),
            totalSize: DownloadIO.formatMB(totalBytes),
            stage: "MP3: probing sizes"
        ))

        for (index, item) in items.enumerated() {
            if Task.isCancelled || terminated.contains(task.bid) {
                await cancellationFlag.set(true)
                throw CancellationError()
            }
            guard let source = URL(string: item.fileURL) else { continue }
            let filename = DownloadIO.itemFilename(index: index, title: item.title, ext: "mp3")
            let dest = destination.appendingPathComponent(filename)

            let expected = index < expectedSizes.count ? expectedSizes[index] : 0
            let downloaded = try await DownloadIO.writeMP3(
                from: source,
                to: dest,
                cancellationFlag: cancellationFlag
            )
            doneBytes += (expected > 0 ? expected : downloaded)
            let percent = min(100, (Double(doneBytes) / Double(totalBytes)) * 100)
            onProgress(Self.makeProgress(
                bid: task.bid,
                status: .downloading,
                percent: percent,
                doneSize: DownloadIO.formatMB(doneBytes),
                totalSize: DownloadIO.formatMB(totalBytes),
                stage: "MP3: file \(index + 1)/\(items.count)"
            ))
        }
    }

    private func downloadM3U8Book(
        task: DownloadTaskInfo,
        destination: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        cancellationFlag: DownloadIO.CancellationFlag
    ) async throws {
        let items = task.book.items.sorted { $0.fileIndex < $1.fileIndex }
        guard !items.isEmpty else { return }

        for (index, item) in items.enumerated() {
            if Task.isCancelled || terminated.contains(task.bid) {
                await cancellationFlag.set(true)
                throw CancellationError()
            }
            guard let source = URL(string: item.fileURL) else { continue }
            let filename = DownloadIO.itemFilename(index: index, title: item.title, ext: "m4a")
            let dest = destination.appendingPathComponent(filename)

            do {
                try await DownloadIO.exportM3U8(
                    sourceURL: source,
                    to: dest,
                    timeRange: nil,
                    onProgress: { fileProgress in
                        let global = ((Double(index) + fileProgress) / Double(max(1, items.count))) * 100
                        onProgress(Self.makeProgress(
                            bid: task.bid,
                            status: .downloading,
                            percent: global,
                            doneSize: "\(Int(global))%",
                            totalSize: "100%",
                            stage: "HLS: file \(index + 1)/\(items.count)"
                        ))
                    },
                    cancellationFlag: cancellationFlag
                )
            } catch {
                guard shouldFallbackToFFmpegForM3U8(error) else {
                    throw error
                }

                if FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.removeItem(at: dest)
                }

                let expectedDuration = max(1, item.endTime - item.startTime)

                onProgress(Self.makeProgress(
                    bid: task.bid,
                    status: .downloading,
                    percent: (Double(index) / Double(max(1, items.count))) * 100,
                    doneSize: "\(index)/\(items.count)",
                    totalSize: "~",
                    stage: "HLS(ffmpeg-copy): file \(index + 1)/\(items.count)"
                ))

                try await DownloadIO.remuxM3U8ToM4AWithFFmpeg(
                    input: source,
                    outputM4A: dest,
                    cancellationFlag: cancellationFlag,
                    onTick: { elapsed, bytes in
                        let fileProgress = min(1, max(0, elapsed / Double(expectedDuration)))
                        let global = ((Double(index) + fileProgress) / Double(max(1, items.count))) * 100
                        onProgress(Self.makeProgress(
                            bid: task.bid,
                            status: .downloading,
                            percent: global,
                            doneSize: DownloadIO.formatMB(bytes),
                            totalSize: "~",
                            stage: "HLS(ffmpeg-copy): file \(index + 1)/\(items.count)"
                        ))
                    }
                )
            }
        }
    }

    private func shouldFallbackToFFmpegForM3U8(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "AVFoundationErrorDomain", nsError.code == -11838 {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == "NSOSStatusErrorDomain",
           underlying.code == -16976 {
            return true
        }

        return false
    }

    private func downloadMergedM3U8Book(
        task: DownloadTaskInfo,
        destination: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void,
        cancellationFlag: DownloadIO.CancellationFlag
    ) async throws {
        let items = task.book.items.sorted { $0.fileIndex < $1.fileIndex }
        guard let masterURLString = items.first?.fileURL,
              let source = URL(string: masterURLString)
        else {
            return
        }

        if task.book.driver == "AKniga" {
            try await AKnigaSegmentDownloader.downloadBook(
                m3u8URL: source,
                referer: task.book.url,
                chapters: items,
                destination: destination,
                cancellationFlag: cancellationFlag,
                onProgress: { stage, percent, doneBytes, diagnostic in
                    onProgress(Self.makeProgress(
                        bid: task.bid,
                        status: .downloading,
                        percent: percent,
                        doneSize: DownloadIO.formatMB(doneBytes),
                        totalSize: "~",
                        stage: stage,
                        errorMessage: diagnostic ?? ""
                    ))
                }
            )
            return
        }

        if Task.isCancelled || terminated.contains(task.bid) {
            await cancellationFlag.set(true)
            throw CancellationError()
        }

        for (index, item) in items.enumerated() {
            if Task.isCancelled || terminated.contains(task.bid) {
                await cancellationFlag.set(true)
                throw CancellationError()
            }
            if item.endTime <= item.startTime {
                throw CloneError.connectionIssue("AKniga: invalid chapter time range at index \(index)")
            }
            let filename = DownloadIO.itemFilename(index: index, title: item.title, ext: "mp3")
            let dest = destination.appendingPathComponent(filename)

            onProgress(Self.makeProgress(
                bid: task.bid,
                status: .downloading,
                percent: (Double(index) / Double(max(1, items.count))) * 100,
                doneSize: "\(index)/\(items.count)",
                totalSize: "~",
                stage: "AKniga: ffmpeg chapter \(index + 1)/\(items.count)"
            ))

            let chapterDuration = max(1, item.endTime - item.startTime)

            try await DownloadIO.exportAudioWithFFmpeg(
                input: source,
                outputMP3: dest,
                startSeconds: max(0, item.startTime),
                endSeconds: max(item.startTime + 1, item.endTime),
                cancellationFlag: cancellationFlag,
                referer: task.book.url,
                onTick: { elapsed, bytes in
                    let chapterProgress = min(1, max(0, elapsed / Double(chapterDuration)))
                    let global = ((Double(index) + chapterProgress) / Double(max(1, items.count))) * 100
                    onProgress(Self.makeProgress(
                        bid: task.bid,
                        status: .downloading,
                        percent: global,
                        doneSize: DownloadIO.formatMB(bytes),
                        totalSize: "~",
                        stage: "AKniga: ffmpeg chapter \(index + 1)/\(items.count)"
                    ))
                }
            )

            if Task.isCancelled || terminated.contains(task.bid) {
                await cancellationFlag.set(true)
                throw CancellationError()
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if fileSize <= 0 {
                throw CloneError.connectionIssue("AKniga: ffmpeg produced empty chapter file at index \(index)")
            }

            if !(FileManager.default.fileExists(atPath: dest.path)) {
                throw CloneError.connectionIssue("AKniga: ffmpeg did not create chapter file at index \(index)")
            }

            let global = (Double(index + 1) / Double(max(1, items.count))) * 100
            onProgress(Self.makeProgress(
                bid: task.bid,
                status: .downloading,
                percent: global,
                doneSize: DownloadIO.formatMB(fileSize),
                totalSize: "~",
                stage: "AKniga: ffmpeg chapter \(index + 1)/\(items.count)"
            ))

        }
    }
}
