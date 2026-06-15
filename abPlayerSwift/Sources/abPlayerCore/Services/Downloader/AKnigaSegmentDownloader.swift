import CommonCrypto
import Foundation
import ffmpegkit

enum AKnigaSegmentError: Error {
    case invalidPlaylist
    case keyNotFound
    case decryptFailed
    case ffmpegFailed(String)
    case chapterMergeInputEmpty(Int)
}

extension AKnigaSegmentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPlaylist:
            return "AKniga: invalid m3u8 playlist"
        case .keyNotFound:
            return "AKniga: encryption key not found"
        case .decryptFailed:
            return "AKniga: TS decrypt failed"
        case let .ffmpegFailed(message):
            return "AKniga ffmpeg: \(message)"
        case let .chapterMergeInputEmpty(index):
            return "AKniga: chapter \(index + 1) has no TS segments"
        }
    }
}

struct AKnigaSegmentDownloader {
    struct Segment {
        let index: Int
        let duration: Double
        let url: URL
    }

    private struct Playlist {
        let baseURL: URL
        let keyURL: URL
        let mediaSequence: Int
        let segments: [Segment]
    }

    static func downloadBook(
        m3u8URL: URL,
        referer: String,
        chapters: [BookItem],
        destination: URL,
        cancellationFlag: DownloadIO.CancellationFlag,
        onProgress: @escaping @Sendable (_ stage: String, _ percent: Double, _ doneBytes: Int64, _ diagnostic: String?) -> Void
    ) async throws {
        let playlist = try await fetchPlaylist(url: m3u8URL, referer: referer)
        let key = try await fetchData(url: playlist.keyURL, referer: referer)
        guard key.count == kCCKeySizeAES128 else {
            throw AKnigaSegmentError.keyNotFound
        }

        try DownloadIO.ensureDirectoryPath(destination)
        let tempRoot = destination.appendingPathComponent(".ak_tmp", isDirectory: true)
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try DownloadIO.ensureDirectoryPath(tempRoot)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let chapterRanges = computeChapterRanges(chapters: chapters, segments: playlist.segments)
        var processed: Int = 0
        let total = max(1, chapterRanges.count)

        for (chapterIndex, range) in chapterRanges.enumerated() {
            if await cancellationFlag.value() { throw CancellationError() }

            let chapterDir = tempRoot.appendingPathComponent("chapter_\(chapterIndex)", isDirectory: true)
            try DownloadIO.ensureDirectoryPath(chapterDir)
            let chapterTS = chapterDir.appendingPathComponent("chapter.ts")
            FileManager.default.createFile(atPath: chapterTS.path, contents: nil)
            let chapterHandle = try FileHandle(forWritingTo: chapterTS)
            defer {
                try? chapterHandle.close()
            }

            var segmentCount = 0
            var doneBytes: Int64 = 0

            for segIndex in range {
                if await cancellationFlag.value() { throw CancellationError() }
                guard segIndex >= 0, segIndex < playlist.segments.count else { continue }
                let seg = playlist.segments[segIndex]
                let encrypted = try await fetchData(url: seg.url, referer: referer)
                let decrypted = try decryptSegment(
                    encrypted,
                    key: key,
                    iv: ivForSegment(mediaSequence: playlist.mediaSequence, segmentIndex: seg.index)
                )
                try chapterHandle.write(contentsOf: decrypted)
                segmentCount += 1
                doneBytes += Int64(decrypted.count)

                let chapterPart = Double(segIndex - range.lowerBound + 1) / Double(max(1, range.count))
                let global = (Double(chapterIndex) + chapterPart) / Double(total)
                onProgress("AKniga: segment \(segIndex + 1)/\(playlist.segments.count)", global * 100, doneBytes, nil)
            }

            let output = destination.appendingPathComponent(DownloadIO.itemFilename(index: chapterIndex, title: chapters[chapterIndex].title, ext: "mp3"))
            let tempOutput = chapterDir.appendingPathComponent("chapter.mp3")
            if segmentCount == 0 {
                throw AKnigaSegmentError.chapterMergeInputEmpty(chapterIndex)
            }
            try chapterHandle.close()
            let chapterDuration = max(1, chapters[chapterIndex].endTime - chapters[chapterIndex].startTime)
            let mergeStage = "AKniga: ffmpeg merge chapter \(chapterIndex + 1)/\(total) with \(segmentCount) segments"
            onProgress(mergeStage, (Double(chapterIndex) / Double(total)) * 100, doneBytes, nil)
            if FileManager.default.fileExists(atPath: tempOutput.path) {
                try? FileManager.default.removeItem(at: tempOutput)
            }
            try await mergeTsToMP3(
                tsInput: chapterTS,
                output: tempOutput,
                cancellationFlag: cancellationFlag,
                estimatedDurationSeconds: chapterDuration,
                onTick: { mergeSeconds, mergeSize in
                    let mergePart = min(1, max(0, mergeSeconds / Double(chapterDuration)))
                    let global = ((Double(chapterIndex) + 0.85 + 0.15 * mergePart) / Double(total)) * 100
                    onProgress(mergeStage, global, mergeSize, nil)
                },
                onStderr: { line in
                    let attrs = try? FileManager.default.attributesOfItem(atPath: tempOutput.path)
                    let mergeSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    let global = ((Double(chapterIndex) + 0.9) / Double(total)) * 100
                    onProgress(mergeStage, global, mergeSize, line)
                }
            )

            let tempExists = FileManager.default.fileExists(atPath: tempOutput.path)
            let tempAttrs = try? FileManager.default.attributesOfItem(atPath: tempOutput.path)
            let tempSize = (tempAttrs?[.size] as? NSNumber)?.int64Value ?? 0
            if !tempExists || tempSize <= 0 {
                throw AKnigaSegmentError.ffmpegFailed("chapter \(chapterIndex + 1): temporary output file not created or empty")
            }

            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: tempOutput, to: output)

            let exists = FileManager.default.fileExists(atPath: output.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if !exists || size <= 0 {
                throw AKnigaSegmentError.ffmpegFailed("chapter \(chapterIndex + 1): output file not created or empty")
            }

            try? FileManager.default.removeItem(at: chapterDir)

            processed += 1
            let global = Double(processed) / Double(total)
            onProgress("AKniga: merged chapter \(processed)/\(total)", global * 100, size, nil)
        }

        onProgress("AKniga: cleanup", 100, 0, nil)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private static func computeChapterRanges(chapters: [BookItem], segments: [Segment]) -> [ClosedRange<Int>] {
        guard !segments.isEmpty else {
            return chapters.map { _ in 0 ... 0 }
        }

        // Map chapter start/end times to real segment boundaries using cumulative
        // EXTINF durations. Using only the first segment duration can drastically
        // overestimate the range when the playlist has variable segment sizes.
        var segmentStarts: [Double] = []
        var segmentEnds: [Double] = []
        segmentStarts.reserveCapacity(segments.count)
        segmentEnds.reserveCapacity(segments.count)

        var t: Double = 0
        for seg in segments {
            let d = max(0.001, seg.duration)
            segmentStarts.append(t)
            t += d
            segmentEnds.append(t)
        }

        func upperBound(_ values: [Double], _ target: Double) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let mid = (low + high) / 2
                if values[mid] <= target {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        func lowerBound(_ values: [Double], _ target: Double) -> Int {
            var low = 0
            var high = values.count
            while low < high {
                let mid = (low + high) / 2
                if values[mid] < target {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        let lastIndex = segments.count - 1
        return chapters.map { item in
            let startTime = max(0, Double(item.startTime))
            let endTime = max(startTime + 1, Double(item.endTime))

            // First segment whose end is strictly after chapter start.
            var start = upperBound(segmentEnds, startTime)
            if start > lastIndex {
                start = lastIndex
            }

            // First segment whose start is >= chapter end.
            var endExclusive = lowerBound(segmentStarts, endTime)
            if endExclusive <= start {
                endExclusive = start + 1
            }
            let end = min(lastIndex, endExclusive - 1)

            return start ... max(start, end)
        }
    }

    private static func fetchPlaylist(url: URL, referer: String) async throws -> Playlist {
        let playlistData = try await fetchData(url: url, referer: referer)
        let text = String(decoding: playlistData, as: UTF8.self)
        let lines = text.split(whereSeparator: \ .isNewline).map(String.init)

        guard let keyLine = lines.first(where: { $0.hasPrefix("#EXT-X-KEY:") }) else {
            throw AKnigaSegmentError.invalidPlaylist
        }
        guard let uriRange = keyLine.range(of: "URI=\"") else { throw AKnigaSegmentError.invalidPlaylist }
        let keyStart = keyLine.index(uriRange.upperBound, offsetBy: 0)
        guard let keyEnd = keyLine[keyStart...].firstIndex(of: "\"") else { throw AKnigaSegmentError.invalidPlaylist }
        let keyPath = String(keyLine[keyStart..<keyEnd])
        guard let keyURL = URL(string: keyPath, relativeTo: url)?.absoluteURL else {
            throw AKnigaSegmentError.invalidPlaylist
        }

        let mediaSequence: Int = {
            guard let line = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }) else { return 0 }
            return Int(line.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")) ?? 0
        }()

        var segments: [Segment] = []
        var currentDuration: Double = 0
        var seqIndex = 0
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let value = line.replacingOccurrences(of: "#EXTINF:", with: "").replacingOccurrences(of: ",", with: "")
                currentDuration = Double(value) ?? 30
            } else if !line.hasPrefix("#") && !line.isEmpty {
                guard let segURL = URL(string: line, relativeTo: url)?.absoluteURL else { continue }
                segments.append(Segment(index: seqIndex, duration: currentDuration, url: segURL))
                seqIndex += 1
            }
        }

        guard !segments.isEmpty else {
            throw AKnigaSegmentError.invalidPlaylist
        }

        return Playlist(baseURL: url, keyURL: keyURL, mediaSequence: mediaSequence, segments: segments)
    }

    private static func fetchData(url: URL, referer: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(DriverHTTP.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://akniga.org", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw CloneError.connectionIssue("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) on \(url.absoluteString)")
        }
        return data
    }

    private static func dataFromHex(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<n], radix: 16) {
                bytes.append(b)
            }
            i = n
        }
        return Data(bytes)
    }

    private static func ivForSegment(mediaSequence: Int, segmentIndex: Int) -> Data {
        let value = UInt32(mediaSequence + segmentIndex)
        var bytes = Data(repeating: 0, count: 16)
        bytes[12] = UInt8((value >> 24) & 0xFF)
        bytes[13] = UInt8((value >> 16) & 0xFF)
        bytes[14] = UInt8((value >> 8) & 0xFF)
        bytes[15] = UInt8(value & 0xFF)
        return bytes
    }

    private static func decryptSegment(_ input: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        var out = Data(repeating: 0, count: input.count + kCCBlockSizeAES128)
        let outCapacity = out.count

        let status = out.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress,
                            input.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw AKnigaSegmentError.decryptFailed
        }
        out.count = outLength
        return out
    }

    private static func mergeTsToMP3(
        tsInput: URL,
        output: URL,
        cancellationFlag: DownloadIO.CancellationFlag,
        estimatedDurationSeconds: Int,
        onTick: @escaping @Sendable (_ mergedSeconds: Double, _ outputBytes: Int64) -> Void,
        onStderr: @escaping @Sendable (_ line: String) -> Void
    ) async throws {
        let inputExists = FileManager.default.fileExists(atPath: tsInput.path)
        let inputAttrs = try? FileManager.default.attributesOfItem(atPath: tsInput.path)
        let inputSize = (inputAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        if !inputExists || inputSize <= 0 {
            throw AKnigaSegmentError.ffmpegFailed("chapter TS input file not created or empty")
        }

        let parent = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let args = [
            "-y",
            "-v", "error",
            "-nostdin",
            "-fflags", "+genpts",
            "-avoid_negative_ts", "make_zero",
            "-i", tsInput.path,
            "-map", "0:a",
            "-c:a", "libmp3lame",
            "-q:a", "4",
            "-compression_level", "0",
            "-threads", "0",
            output.path
        ]

        let state = FFmpegExecutionState()
        let session = FFmpegKit.executeAsync(
            DownloadIO.quoteFFmpegArgs(args),
            withCompleteCallback: { session in
                state.complete(with: session)
            },
            withLogCallback: { log in
                guard let line = log?.getMessage()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                    return
                }
                onStderr(line)
            },
            withStatisticsCallback: { stats in
                guard let stats else { return }
                let mergedSeconds = stats.getTime() / 1000.0
                let mergedSize = Int64(stats.getSize())
                onTick(mergedSeconds, mergedSize)
            }
        )
        state.setRunningSession(session)

        let deadline = Date().addingTimeInterval(TimeInterval(max(900, estimatedDurationSeconds * 6)))
        let mergeStarted = Date()
        while true {
            let snapshot = state.snapshot()
            if snapshot.completed {
                break
            }

            if await cancellationFlag.value() {
                FFmpegKit.cancel()
                throw CancellationError()
            }
            if Date() > deadline {
                FFmpegKit.cancel()
                throw AKnigaSegmentError.ffmpegFailed("merge timeout")
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
            let outSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            onTick(Date().timeIntervalSince(mergeStarted), outSize)
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        let finalSession = state.snapshot().session
        guard let finalSession else {
            throw AKnigaSegmentError.ffmpegFailed("merge failed: session missing")
        }
        let returnCode = finalSession.getReturnCode()
        if ReturnCode.isCancel(returnCode) {
            throw CancellationError()
        }
        if !ReturnCode.isSuccess(returnCode) {
            let stderrText = finalSession.getFailStackTrace() ?? finalSession.getOutput() ?? ""
            let msg = stderrText.isEmpty ? "merge failed" : stderrText
            throw AKnigaSegmentError.ffmpegFailed(msg)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
        let outSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        onTick(Double(estimatedDurationSeconds), outSize)
    }
}
