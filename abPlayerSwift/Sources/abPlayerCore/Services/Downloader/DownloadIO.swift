import AVFoundation
import Foundation
import ffmpegkit

enum FFmpegError: Error {
    case failed(String)
}

final class FFmpegExecutionState {
    private let lock = NSLock()
    private var runningSession: FFmpegSession?
    private var completedSession: FFmpegSession?
    private var completed = false

    func setRunningSession(_ session: FFmpegSession?) {
        lock.lock()
        runningSession = session
        lock.unlock()
    }

    func complete(with session: FFmpegSession?) {
        lock.lock()
        completedSession = session
        completed = true
        lock.unlock()
    }

    func snapshot() -> (completed: Bool, session: FFmpegSession?) {
        lock.lock()
        let result = (completed, completedSession ?? runningSession)
        lock.unlock()
        return result
    }

}

@MainActor private var ffmpegSilenceConfigured = false

@MainActor
private func ensureFFmpegLogsSuppressed() {
    guard !ffmpegSilenceConfigured else {
        return
    }
    FFmpegKitConfig.disableRedirection()
    FFmpegKitConfig.setLogLevel(-8)
    ffmpegSilenceConfigured = true
}

enum DownloadIO {
    enum CoverImageFormat: String {
        case jpg
        case png
    }

    actor CancellationFlag {
        private var cancelled = false

        func set(_ value: Bool) {
            cancelled = value
        }

        func value() -> Bool {
            cancelled
        }
    }

    static func ensureDirectoryPath(_ directoryURL: URL) throws {
        let fm = FileManager.default

        func ensure(_ url: URL) throws {
            let parent = url.deletingLastPathComponent()
            if parent.path != url.path {
                try ensure(parent)
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return
                }
                // Recover from stale file-vs-directory conflicts in old download layouts.
                try fm.removeItem(at: url)
            }

            try fm.createDirectory(at: url, withIntermediateDirectories: false)
#if os(iOS)
            try? fm.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: url.path)
#endif
        }

        try ensure(directoryURL)
    }

    static func writeMP3(
        from sourceURL: URL,
        to destinationURL: URL,
        cancellationFlag: CancellationFlag
    ) async throws -> Int64 {
        if await cancellationFlag.value() {
            throw CancellationError()
        }
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw CloneError.connectionIssue("HTTP error on \(sourceURL.absoluteString)")
        }

        if await cancellationFlag.value() {
            throw CancellationError()
        }

        let fm = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try ensureDirectoryPath(parent)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        fm.createFile(atPath: destinationURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        return Int64(data.count)
    }

    static func exportM3U8(
        sourceURL: URL,
        to destinationURL: URL,
        timeRange: CMTimeRange?,
        onProgress: @escaping @Sendable (Double) -> Void,
        cancellationFlag: CancellationFlag
    ) async throws {
        let fm = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try ensureDirectoryPath(parent)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CloneError.connectionIssue("Cannot initialize AVAssetExportSession")
        }
        if sourceURL.isFileURL {
            _ = try await asset.load(.duration)
        }
        export.outputURL = destinationURL
        export.outputFileType = .m4a
        if let timeRange {
            export.timeRange = timeRange
        }

        export.exportAsynchronously {}
        while export.status == .waiting || export.status == .exporting {
            if await cancellationFlag.value() {
                export.cancelExport()
                throw CancellationError()
            }
            onProgress(Double(export.progress))
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        onProgress(1)

        switch export.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw export.error ?? CloneError.connectionIssue("M3U8 export failed")
        default:
            throw CloneError.connectionIssue("Unexpected export status")
        }
    }

    static func contentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode),
                  let value = http.value(forHTTPHeaderField: "Content-Length"),
                  let length = Int64(value)
            else {
                return nil
            }
            return length
        } catch {
            return nil
        }
    }

    static func safePathComponent(_ value: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|+")
        let cleaned = value.components(separatedBy: bad).joined()
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static func destinationDirectory(for book: Book, rootPath: String) -> URL {
        var url = URL(fileURLWithPath: rootPath, isDirectory: true)
        let author = safePathComponent(book.author)
        if !author.isEmpty {
            url.appendPathComponent(author, isDirectory: true)
        }
        if !book.seriesName.isEmpty {
            url.appendPathComponent(safePathComponent(book.seriesName), isDirectory: true)
            if !book.numberInSeries.isEmpty {
                url.appendPathComponent("\(book.numberInSeries). \(safePathComponent(book.name))", isDirectory: true)
            } else {
                url.appendPathComponent(safePathComponent(book.name), isDirectory: true)
            }
        } else {
            url.appendPathComponent(safePathComponent(book.name), isDirectory: true)
        }
        if book.items.count > 1, !book.reader.isEmpty {
            url.appendPathComponent(safePathComponent(book.reader), isDirectory: true)
        }
        return url
    }

    static func itemFilename(index: Int, title: String, ext: String) -> String {
        let i = String(index + 1).padding(toLength: 2, withPad: "0", startingAt: 0)
        let safeTitle = safePathComponent(title.isEmpty ? "Chapter \(index + 1)" : title)
        return "\(i). \(safeTitle).\(ext)"
    }

    static func formatMB(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let value = Double(bytes) / 1_048_576
        return String(format: "%.2f MB", value)
    }

    static func descriptionText(
        for book: Book,
        language: DownloadTaskInfo.DescriptionLanguage
    ) -> String {
        let labels: (title: String, authors: String, readers: String, description: String)
        switch language {
        case .en:
            labels = (
                title: "Title",
                authors: "Author(s)",
                readers: "Reader(s)",
                description: "Description"
            )
        case .ru:
            labels = (
                title: "Название",
                authors: "Автор(ы)",
                readers: "Чтец(ы)",
                description: "Описание"
            )
        }

        return [
            "\(labels.title): \(book.name)",
            "\(labels.authors): \(book.author)",
            "\(labels.readers): \(book.reader)",
            "\(labels.description): \(book.description)"
        ].joined(separator: "\n") + "\n"
    }

    static func writeDescriptionFile(
        for book: Book,
        language: DownloadTaskInfo.DescriptionLanguage,
        in directory: URL
    ) throws {
        let fileURL = directory.appendingPathComponent("Description.txt", isDirectory: false)
        let text = descriptionText(for: book, language: language)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func saveCoverIfAvailable(for book: Book, in directory: URL) async {
        let trimmed = book.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed)
        else {
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(DriverHTTP.defaultUserAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode)
            else {
                return
            }

            guard let format = detectCoverImageFormat(
                data: data,
                mimeType: http.value(forHTTPHeaderField: "Content-Type"),
                sourceURL: url
            ) else {
                return
            }

            let fm = FileManager.default
            for oldName in ["cover.jpg", "cover.png"] {
                let oldPath = directory.appendingPathComponent(oldName).path
                if fm.fileExists(atPath: oldPath) {
                    try? fm.removeItem(atPath: oldPath)
                }
            }

            let outURL = directory.appendingPathComponent("cover.\(format.rawValue)", isDirectory: false)
            try data.write(to: outURL, options: .atomic)
        } catch {
            // Cover is optional. Ignore failures to avoid interrupting successful audio downloads.
        }
    }

    static func detectCoverImageFormat(
        data: Data,
        mimeType: String?,
        sourceURL: URL
    ) -> CoverImageFormat? {
        if let mimeType {
            let mime = mimeType.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if mime == "image/jpeg" || mime == "image/jpg" {
                return .jpg
            }
            if mime == "image/png" {
                return .png
            }
        }

        let ext = sourceURL.pathExtension.lowercased()
        if ext == "jpg" || ext == "jpeg" {
            return .jpg
        }
        if ext == "png" {
            return .png
        }

        if data.count >= 3,
           data[0] == 0xFF,
           data[1] == 0xD8,
           data[2] == 0xFF
        {
            return .jpg
        }

        if data.count >= 8,
           data[0] == 0x89,
           data[1] == 0x50,
           data[2] == 0x4E,
           data[3] == 0x47,
           data[4] == 0x0D,
           data[5] == 0x0A,
           data[6] == 0x1A,
           data[7] == 0x0A
        {
            return .png
        }

        return nil
    }

    static func exportAudioWithFFmpeg(
        input: URL,
        outputMP3: URL,
        startSeconds: Int,
        endSeconds: Int,
        cancellationFlag: CancellationFlag,
        rwTimeoutMicros: Int = 20_000_000,
        processTimeoutSeconds: TimeInterval? = nil,
        referer: String? = nil,
        onTick: @escaping @Sendable (_ elapsed: TimeInterval, _ outputBytes: Int64) -> Void = { _, _ in }
    ) async throws {
        await ensureFFmpegLogsSuppressed()
        let duration = max(1, endSeconds - startSeconds)

        let fm = FileManager.default
        let parent = outputMP3.deletingLastPathComponent()
        try ensureDirectoryPath(parent)
        if fm.fileExists(atPath: outputMP3.path) {
            try fm.removeItem(at: outputMP3)
        }
        _ = fm.createFile(atPath: outputMP3.path, contents: nil)

        let inputPath = input.isFileURL ? input.path : input.absoluteString
        var args = [
            "-y",
            "-v", "error",
            "-user_agent", DriverHTTP.defaultUserAgent,
            "-rw_timeout", String(rwTimeoutMicros),
            "-ss", String(startSeconds),
            "-t", String(duration),
            "-i", inputPath,
            "-map", "0:a",
            "-c:a", "libmp3lame",
            outputMP3.path
        ]
        if let referer, !referer.isEmpty {
            let headers = "Referer: \(referer)\r\nOrigin: https://akniga.org\r\n"
            args.insert(contentsOf: ["-headers", headers], at: 8)
        }

        let state = FFmpegExecutionState()
        let session = FFmpegKit.executeAsync(
            quoteFFmpegArgs(args),
            withCompleteCallback: { session in
                state.complete(with: session)
            },
            withLogCallback: nil,
            withStatisticsCallback: nil,
            onDispatchQueue: DispatchQueue.global(qos: .utility)
        )
        state.setRunningSession(session)

        let deadline = processTimeoutSeconds.map { Date().addingTimeInterval($0) }
        let startedAt = Date()
        while true {
            let snapshot = state.snapshot()
            if snapshot.completed {
                break
            }

            if await cancellationFlag.value() {
                FFmpegKit.cancel()
                throw CancellationError()
            }
            if let deadline, Date() > deadline {
                FFmpegKit.cancel()
                throw FFmpegError.failed("ffmpeg timeout after \(Int(processTimeoutSeconds ?? 0))s")
            }

            let attrs = try? fm.attributesOfItem(atPath: outputMP3.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            onTick(Date().timeIntervalSince(startedAt), size)

            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let attrs = try? fm.attributesOfItem(atPath: outputMP3.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onTick(TimeInterval(duration), size)

        let finalSession = state.snapshot().session
        guard let finalSession else {
            throw FFmpegError.failed("ffmpeg failed: session missing")
        }
        let returnCode = finalSession.getReturnCode()
        if ReturnCode.isCancel(returnCode) {
            throw CancellationError()
        }
        if !ReturnCode.isSuccess(returnCode) {
            let message = finalSession.getFailStackTrace() ?? finalSession.getOutput() ?? "ffmpeg failed"
            throw FFmpegError.failed(message)
        }
    }

    static func remuxM3U8ToM4AWithFFmpeg(
        input: URL,
        outputM4A: URL,
        cancellationFlag: CancellationFlag,
        rwTimeoutMicros: Int = 20_000_000,
        processTimeoutSeconds: TimeInterval? = nil,
        referer: String? = nil,
        onTick: @escaping @Sendable (_ elapsed: TimeInterval, _ outputBytes: Int64) -> Void = { _, _ in }
    ) async throws {
        await ensureFFmpegLogsSuppressed()
        let fm = FileManager.default
        let parent = outputM4A.deletingLastPathComponent()
        try ensureDirectoryPath(parent)
        if fm.fileExists(atPath: outputM4A.path) {
            try fm.removeItem(at: outputM4A)
        }
        _ = fm.createFile(atPath: outputM4A.path, contents: nil)

        let inputPath = input.isFileURL ? input.path : input.absoluteString
        var args = [
            "-y",
            "-v", "error",
            "-user_agent", DriverHTTP.defaultUserAgent,
            "-rw_timeout", String(rwTimeoutMicros),
            "-i", inputPath,
            "-map", "0:a",
            "-c:a", "copy",
            outputM4A.path
        ]
        if let referer, !referer.isEmpty {
            let headers = "Referer: \(referer)\r\nOrigin: https://books.yandex.ru\r\n"
            args.insert(contentsOf: ["-headers", headers], at: 8)
        }

        let state = FFmpegExecutionState()
        let session = FFmpegKit.executeAsync(
            quoteFFmpegArgs(args),
            withCompleteCallback: { session in
                state.complete(with: session)
            },
            withLogCallback: nil,
            withStatisticsCallback: nil,
            onDispatchQueue: DispatchQueue.global(qos: .utility)
        )
        state.setRunningSession(session)

        let deadline = processTimeoutSeconds.map { Date().addingTimeInterval($0) }
        let startedAt = Date()
        while true {
            let snapshot = state.snapshot()
            if snapshot.completed {
                break
            }

            if await cancellationFlag.value() {
                FFmpegKit.cancel()
                throw CancellationError()
            }
            if let deadline, Date() > deadline {
                FFmpegKit.cancel()
                throw FFmpegError.failed("ffmpeg timeout after \(Int(processTimeoutSeconds ?? 0))s")
            }

            let attrs = try? fm.attributesOfItem(atPath: outputM4A.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            onTick(Date().timeIntervalSince(startedAt), size)
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let attrs = try? fm.attributesOfItem(atPath: outputM4A.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onTick(Date().timeIntervalSince(startedAt), size)

        let finalSession = state.snapshot().session
        guard let finalSession else {
            throw FFmpegError.failed("ffmpeg failed: session missing")
        }
        let returnCode = finalSession.getReturnCode()
        if ReturnCode.isCancel(returnCode) {
            throw CancellationError()
        }
        if !ReturnCode.isSuccess(returnCode) {
            let message = finalSession.getFailStackTrace() ?? finalSession.getOutput() ?? "ffmpeg failed"
            throw FFmpegError.failed(message)
        }
    }

    static func quoteFFmpegArgs(_ args: [String]) -> String {
        args.map { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
