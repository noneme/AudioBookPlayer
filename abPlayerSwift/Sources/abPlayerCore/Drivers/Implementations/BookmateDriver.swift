import Foundation

public struct BookmateDriver: DriverProtocol {
    public let name = "Bookmate"
    public let siteURL = "https://books.yandex.ru"
    public let isLicensed = true
    public let isAuthenticated: Bool

    private let apiURL = "https://api.bookmate.yandex.net/api/v5"
    private let authToken: String

    public init(authToken: String = "") {
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isAuthenticated = !self.authToken.isEmpty
    }

    public func canHandle(url: String) -> Bool {
        url.hasPrefix(siteURL)
    }

    public func getBook(url: String) async throws -> Book {
        let uuid = extractAudiobookUUID(from: url)

        let metaData = try await DriverHTTP.getData("\(apiURL)/audiobooks/\(uuid)")
        guard
            let metaJSON = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
            let audiobook = metaJSON["audiobook"] as? [String: Any]
        else {
            throw CloneError.connectionIssue("Bookmate: invalid audiobook response")
        }

        let playlistJSON = try await fetchPlaylistJSON(uuid: uuid)
        let tracks = parseTracks(from: playlistJSON)
        if tracks.isEmpty {
            throw CloneError.connectionIssue("Bookmate: tracks list is empty")
        }

        var items: [BookItem] = []
        items.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            guard
                let offline = track["offline"] as? [String: Any],
                let maxBitRate = offline["max_bit_rate"] as? [String: Any],
                let fileURL = maxBitRate["url"] as? String,
                !fileURL.isEmpty
            else {
                continue
            }

            let durationSeconds: Int = {
                if let durationObj = track["duration"] as? [String: Any], let v = intValue(durationObj["seconds"]) {
                    return max(1, v)
                }
                return max(1, intValue(track["duration"]) ?? 1)
            }()

            let title = chapterTitle(track: track, fallbackIndex: index)
            items.append(BookItem(
                fileURL: fileURL,
                fileIndex: index,
                title: title,
                startTime: 0,
                endTime: durationSeconds
            ))
        }

        if items.isEmpty {
            throw CloneError.connectionIssue("Bookmate: failed to parse playable tracks")
        }

        return Book(
            id: abs(url.hashValue),
            author: cleanedText(firstName(in: audiobook["authors"]) ?? "Unknown"),
            name: cleanedText(string(audiobook["title"]) ?? "Unknown"),
            seriesName: cleanedText(firstSeriesTitle(in: audiobook["series_list"]) ?? ""),
            numberInSeries: cleanedText(firstSeriesPosition(in: audiobook["series_list"]) ?? ""),
            description: cleanedText(string(audiobook["annotation"]) ?? ""),
            reader: cleanedText(firstName(in: audiobook["narrators"]) ?? ""),
            duration: DriverParsing.durationFromSeconds(intValue((audiobook["duration"] as? [String: Any])?["seconds"]) ?? intValue(audiobook["duration"]) ?? 0),
            url: "\(siteURL)/audiobooks/\(uuid)",
            preview: coverURL(in: audiobook["cover"]) ?? "",
            driver: self.name,
            items: items
        )
    }

    public func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return [] }

        var output: [BookPreview] = []
        output.reserveCapacity(limit)

        var page = 1
        var remainingOffset = max(0, offset)
        let encodedQuery = DriverHTTP.encodedQuery(trimmed)

        while output.count < limit {
            let pageData = try await DriverHTTP.getData("\(apiURL)/audiobooks/search?query=\(encodedQuery)&page=\(page)")
            guard
                let json = try JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                let objects = json["objects"] as? [[String: Any]]
            else {
                break
            }

            if objects.isEmpty { break }

            var booksPage = objects
            if remainingOffset > 0 {
                if remainingOffset >= booksPage.count {
                    remainingOffset -= booksPage.count
                    page += 1
                    continue
                }
                booksPage = Array(booksPage.dropFirst(remainingOffset))
                remainingOffset = 0
            }

            for raw in booksPage {
                if output.count >= limit { break }
                guard let uuid = string(raw["uuid"]), !uuid.isEmpty else { continue }

                let author = cleanedText(firstName(in: raw["authors"]) ?? "Unknown")
                let title = cleanedText(string(raw["title"]) ?? "")
                if title.isEmpty { continue }

                let seriesName = cleanedText(firstSeriesTitle(in: raw["series_list"]) ?? "")
                let numberInSeries = cleanedText(firstSeriesPosition(in: raw["series_list"]) ?? "")
                let reader = cleanedText(firstName(in: raw["narrators"]) ?? "")
                let duration = DriverParsing.durationFromSeconds(intValue((raw["duration"] as? [String: Any])?["seconds"]) ?? intValue(raw["duration"]) ?? 0)
                let preview = coverURL(in: raw["cover"]) ?? ""

                output.append(BookPreview(
                    author: author,
                    name: title,
                    seriesName: seriesName,
                    numberInSeries: numberInSeries,
                    reader: reader,
                    duration: duration,
                    url: "\(siteURL)/audiobooks/\(uuid)",
                    preview: preview,
                    driver: self.name
                ))
            }

            page += 1
        }

        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] {
        let uuid = extractAudiobookUUID(from: url)

        let data = try await DriverHTTP.getData("\(apiURL)/audiobooks/\(uuid)")
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let audiobook = json["audiobook"] as? [String: Any],
            let seriesList = audiobook["series_list"] as? [[String: Any]],
            let firstSeries = seriesList.first,
            let seriesUUID = string(firstSeries["uuid"]),
            !seriesUUID.isEmpty
        else {
            return []
        }

        let partsData = try await DriverHTTP.getData("\(apiURL)/series/\(seriesUUID)/parts")
        guard
            let partsJSON = try JSONSerialization.jsonObject(with: partsData) as? [String: Any],
            let parts = partsJSON["parts"] as? [[String: Any]]
        else {
            return []
        }

        var output: [BookPreview] = []
        let seriesTitle = cleanedText(string(firstSeries["title"]) ?? "")

        for part in parts {
            guard
                let resource = part["resource"] as? [String: Any],
                let partUUID = string(resource["uuid"]),
                !partUUID.isEmpty
            else {
                continue
            }

            let author = cleanedText(firstName(in: resource["authors"]) ?? "Unknown")
            let title = cleanedText(string(resource["title"]) ?? "")
            if title.isEmpty { continue }

            let reader = cleanedText(firstName(in: resource["narrators"]) ?? "")
            let numberInSeries = cleanedText(string(part["position_label"]) ?? "")
            let duration = DriverParsing.durationFromSeconds(intValue((resource["duration"] as? [String: Any])?["seconds"]) ?? intValue(resource["duration"]) ?? 0)
            let preview = coverURL(in: resource["cover"]) ?? ""

            output.append(BookPreview(
                author: author,
                name: title,
                seriesName: seriesTitle,
                numberInSeries: numberInSeries,
                reader: reader,
                duration: duration,
                url: "\(siteURL)/audiobooks/\(partUUID)",
                preview: preview,
                driver: self.name
            ))
        }

        return output
    }

    private func authHeaders() throws -> [String: String] {
        guard !authToken.isEmpty else {
            throw CloneError.notAuthenticated
        }
        return [
            "auth-token": authToken,
            "Origin": siteURL,
            "Referer": "\(siteURL)/"
        ]
    }

    private func extractAudiobookUUID(from url: String) -> String {
        if let parsed = URL(string: url) {
            let path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let last = path.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
        }
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let last = trimmed.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return trimmed
    }

    private func chapterTitle(track: [String: Any], fallbackIndex: Int) -> String {
        if let title = string(track["title"]), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanedText(title)
        }
        if let chapter = track["chapter"] as? [String: Any],
           let title = string(chapter["title"]),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanedText(title)
        }
        return "Chapter \(fallbackIndex + 1)"
    }

    private func firstName(in value: Any?) -> String? {
        guard let list = value as? [[String: Any]], let first = list.first else { return nil }
        return string(first["name"])
    }

    private func firstSeriesTitle(in value: Any?) -> String? {
        guard let list = value as? [[String: Any]], let first = list.first else { return nil }
        return string(first["title"])
    }

    private func firstSeriesPosition(in value: Any?) -> String? {
        guard let list = value as? [[String: Any]], let first = list.first else { return nil }
        return string(first["position_label"])
    }

    private func coverURL(in value: Any?) -> String? {
        guard let cover = value as? [String: Any] else { return nil }
        if let large = string(cover["large"]), !large.isEmpty {
            return large
        }
        if let small = string(cover["small"]), !small.isEmpty {
            return small
        }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let text = value as? String, let parsed = Int(text) { return parsed }
        return nil
    }

    private func cleanedText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTracks(from json: [String: Any]) -> [[String: Any]] {
        if let tracks = json["tracks"] as? [[String: Any]] {
            return tracks
        }
        if let playlist = json["playlist"] as? [String: Any],
           let tracks = playlist["tracks"] as? [[String: Any]] {
            return tracks
        }
        if let audiobook = json["audiobook"] as? [String: Any],
           let tracks = audiobook["tracks"] as? [[String: Any]] {
            return tracks
        }
        return []
    }

    private func fetchPlaylistJSON(uuid: String) async throws -> [String: Any] {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CloneError.notAuthenticated
        }

        let urlCandidates = [
            "\(apiURL)/audiobooks/\(uuid)/playlists.json",
            "\(apiURL)/audiobooks/\(uuid)/playlists"
        ]

        let headerCandidates: [[String: String]] = [
            ["auth-token": token, "Origin": siteURL, "Referer": "\(siteURL)/"],
            ["Authorization": "OAuth \(token)", "Origin": siteURL, "Referer": "\(siteURL)/"],
            ["Authorization": "Bearer \(token)", "Origin": siteURL, "Referer": "\(siteURL)/"]
        ]

        var lastError = ""

        for path in urlCandidates {
            for headers in headerCandidates {
                let response = try await rawGet(path, headers: headers)

                let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
                if let error = json?["error"] as? String, error == "not_authenticated" {
                    throw CloneError.notAuthenticated
                }

                if (200 ... 299).contains(response.statusCode) {
                    if let json {
                        return json
                    }
                    lastError = "Bookmate: invalid playlist JSON"
                    continue
                }

                if response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 404 {
                    if let json,
                       let errorDescription = json["error_description"] as? String,
                       !errorDescription.isEmpty {
                        lastError = errorDescription
                    } else {
                        lastError = "HTTP \(response.statusCode)"
                    }
                    continue
                }

                if let json,
                   let error = json["error"] as? String,
                   !error.isEmpty {
                    lastError = error
                } else {
                    lastError = "HTTP \(response.statusCode)"
                }
            }
        }

        let suffix = lastError.isEmpty ? "" : " (\(lastError))"
        throw CloneError.connectionIssue("HTTP error on \(apiURL)/audiobooks/\(uuid)/playlists\(suffix)")
    }

    private func rawGet(_ urlString: String, headers: [String: String]) async throws -> (statusCode: Int, data: Data) {
        guard let url = URL(string: urlString) else {
            throw CloneError.connectionIssue("Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(DriverHTTP.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (code, data)
    }
}
