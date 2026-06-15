import Foundation
import SwiftSoup

private func normalizedDescriptionCandidate(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed = value
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? nil : collapsed
}

private func firstNormalizedDescription(_ values: [String?]) -> String {
    for value in values {
        if let normalized = normalizedDescriptionCandidate(value) {
            return normalized
        }
    }
    return ""
}

private func makePreview(
    author: String,
    name: String,
    url: String,
    driver: String,
    reader: String = "",
    duration: String = "",
    series: String = "",
    number: String = "",
    preview: String = ""
) -> BookPreview {
    BookPreview(
        author: author,
        name: name,
        seriesName: series,
        numberInSeries: number,
        reader: reader,
        duration: duration,
        url: url,
        preview: preview,
        driver: driver
    )
}

private func makeBook(from preview: BookPreview) -> Book {
    Book(
        id: abs(preview.url.hashValue),
        author: preview.author,
        name: preview.name,
        seriesName: preview.seriesName,
        numberInSeries: preview.numberInSeries,
        description: "Fetched by \(preview.driver)",
        reader: preview.reader,
        duration: preview.duration,
        url: preview.url,
        preview: preview.preview,
        driver: preview.driver,
        items: [BookItem(fileURL: preview.url + "/audio.mp3", fileIndex: 0, title: "Chapter 1", startTime: 0, endTime: 600)]
    )
}

public struct KnigaVUheDriver: DriverProtocol {
    public let name = "KnigaVUhe"
    public let siteURL = "https://knigavuhe.org"
    public let isLicensed = false
    public let isAuthenticated = true

    public init() {}

    public func canHandle(url: String) -> Bool { url.hasPrefix(siteURL) }

    public func getBook(url: String) async throws -> Book {
        let html = try await DriverHTTP.getString(url)
        let doc = try SwiftSoup.parse(html)

        let pageText = html

        let parsedName = try doc.select("span.book_title_elem").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let pageTitle = try doc.title()
        let name = parsedName ?? pageTitle
        let author = try doc.select("span.book_title_elem > span > a").first()?.text() ?? "Unknown"
        let descriptionMain = try doc.select("div.book_description").first()?.text()
        let descriptionFallback = try doc.select("[itemprop='description']").first()?.text()
        let descriptionMetaOG = try doc.select("meta[property='og:description']").first()?.attr("content")
        let descriptionMeta = try doc.select("meta[name='description']").first()?.attr("content")
        let description = firstNormalizedDescription([
            descriptionMain,
            descriptionFallback,
            descriptionMetaOG,
            descriptionMeta
        ])
        let reader = try doc.select("a[href^='/reader/']").first()?.text() ?? ""
        let duration: String = {
            if let label = try? doc.select("span:contains(Время звучания:)").first(),
               let parentText = try? label.parent()?.text()
            {
                return parentText
                    .replacingOccurrences(of: "Время звучания:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (try? doc.select("span.bookkitem_meta_time").first()?.text()) ?? ""
        }()
        let previewRaw = try doc.select("div.book_cover img").first()?.attr("src") ?? ""
        let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)

        var seriesName = ""
        var numberInSeries = ""
        if let seriesEl = try doc.select("div.book_serie_block_title > a").first() {
            seriesName = try seriesEl.text()
            numberInSeries = try doc.select("div.book_serie_block_item_index").first()?.text().replacingOccurrences(of: ".", with: "") ?? ""
        } else if let titleText = try doc.select("div.book_serie_block_title").first()?.text(), titleText.contains("Цикл:") {
            seriesName = titleText.replacingOccurrences(of: "Цикл:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            numberInSeries = try doc.select("div.book_serie_block_item_index").first()?.text().replacingOccurrences(of: ".", with: "") ?? ""
        }

        let playlist = extractJSONArray(from: pageText, pattern: #"var\s+player\s*=\s*new\s+BookPlayer\(\d+,\s*(\[.+?\])\s*,\s*\["#)
        var items: [BookItem] = []
        if let playlist,
           let data = playlist.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (i, item) in arr.enumerated() {
                let fileURL = (item["url"] as? String) ?? ""
                let title = (item["title"] as? String) ?? "Chapter \(i + 1)"
                let durationFloat = (item["duration_float"] as? Double) ?? Double((item["duration"] as? Int) ?? 0)
                let end = Int(durationFloat)
                items.append(BookItem(fileURL: fileURL, fileIndex: i, title: title, startTime: 0, endTime: max(1, end)))
            }
        }

        return Book(
            id: abs(url.hashValue),
            author: author,
            name: name,
            seriesName: seriesName,
            numberInSeries: numberInSeries,
            description: description,
            reader: reader,
            duration: duration,
            url: url,
            preview: preview,
            driver: self.name,
            items: items
        )
    }

    public func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview] {
        guard query.count >= 3 else { return [] }
        let encoded = DriverHTTP.encodedQuery(query)
        var output: [BookPreview] = []
        var page = 1
        var remainingOffset = offset

        while output.count < limit {
            let html = try await DriverHTTP.getString("\(siteURL)/search/?q=\(encoded)&page=\(page)")
            let doc = try SwiftSoup.parse(html)
            let cards = try doc.select("div.bookkitem")
            let array = cards.array()
            if array.isEmpty { break }

            if remainingOffset >= array.count {
                remainingOffset -= array.count
                page += 1
                continue
            }

            for card in array.dropFirst(remainingOffset) {
                if output.count >= limit { break }

                let urlPath = try card.select("a.bookkitem_cover").first()?.attr("href") ?? ""
                if urlPath.isEmpty { continue }

                let title = try card.select("a.bookkitem_name").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let author = try card.select("span.bookkitem_author a").first()?.text() ?? "Unknown"
                let reader = try card.select("a[href^='/reader/']").first()?.text() ?? ""
                let duration = try card.select("span.bookkitem_meta_time").first()?.text() ?? ""
                let series = try card.select("a[href^='/serie/']").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let number = try card.select("span.bookkitem_serie_index").first()?.text().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let previewRaw = try card.select("img.bookkitem_cover_img").first()?.attr("src") ?? ""
                let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)

                output.append(
                    makePreview(
                        author: author,
                        name: title,
                        url: DriverParsing.absoluteURL(host: siteURL, path: urlPath),
                        driver: self.name,
                        reader: reader,
                        duration: duration,
                        series: series,
                        number: number,
                        preview: preview
                    )
                )
            }

            remainingOffset = 0
            page += 1
        }
        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] { [] }
}

public struct IzibukDriver: DriverProtocol {
    public let name = "Izibuk"
    public let siteURL = "https://izib.uk"
    public let isLicensed = false
    public let isAuthenticated = true

    public init() {}

    public func canHandle(url: String) -> Bool { url.hasPrefix(siteURL) }
    public func getBook(url: String) async throws -> Book {
        let html = try await DriverHTTP.getString(url)
        let doc = try SwiftSoup.parse(html)

        let parsedTitle = try doc.select("[itemprop='name']").first()?.text()
        let pageTitle = try doc.title()
        let title = parsedTitle ?? pageTitle
        let author = try doc.select("span a[href^='/author']").first()?.text() ?? "Unknown"
        let description = try doc.select("[itemprop='description']").first()?.text() ?? ""
        let reader = try doc.select("a[href~=^/reader\\d+$]").first()?.text() ?? ""
        
        let duration = try doc.select("b:matchesOwn(^Время:$)").first()?.parent()?.ownText().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
      
        let previewRaw = try doc.select("img").first()?.attr("src") ?? ""
        let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)
        let seriesName = try doc.select("a[href^='/serie']").first()?.text() ?? ""
        let numberInSeries = try doc.select("span._bb8bca").first()?.text().replacingOccurrences(of: ".", with: "") ?? ""

        let playerJSON = extractJSONObject(from: html, pattern: #"var\s+player\s*=\s*new\s+XSPlayer\((\{.+?\})\);"#)
        var items: [BookItem] = []
        if let playerJSON,
           let data = playerJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let prefix = obj["mp3_url_prefix"] as? String,
           let tracks = obj["tracks"] as? [[Any]] {
            let host = prefix.hasPrefix("http") ? prefix : "https://\(prefix)"
            for (i, row) in tracks.enumerated() {
                guard row.count >= 5 else { continue }
                let chapterTitle = String(describing: row[1])
                let end = (row[2] as? Int) ?? Int((row[2] as? Double) ?? 0)
                let file = String(describing: row[4])
                items.append(
                    BookItem(
                        fileURL: "\(host)/\(file)",
                        fileIndex: i,
                        title: chapterTitle,
                        startTime: 0,
                        endTime: max(1, end)
                    )
                )
            }
        }

        return Book(
            id: abs(url.hashValue),
            author: author,
            name: title,
            seriesName: seriesName,
            numberInSeries: numberInSeries,
            description: description,
            reader: reader,
            duration: duration,
            url: url,
            preview: preview,
            driver: self.name,
            items: items
        )
    }

    public func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview] {
        guard query.count >= 3 else { return [] }
        let encoded = DriverHTTP.encodedQuery(query)
        var output: [BookPreview] = []
        var page = 1
        var remainingOffset = offset

        while output.count < limit {
            let html = try await DriverHTTP.getString("\(siteURL)/search?q=\(encoded)&p=\(page)")
            let doc = try SwiftSoup.parse(html)
            let cards = try doc.select("div#books_list div._ccb9b7")
            let array = cards.array()
            if array.isEmpty { break }

            if remainingOffset >= array.count {
                remainingOffset -= array.count
                page += 1
                continue
            }

            for card in array.dropFirst(remainingOffset) {
                if output.count >= limit { break }

                let titleLink = try card.select("div._3dc935 a[href^='/art']").first()
                guard let titleLink else { continue }
                let urlPath = try titleLink.attr("href")
                let title = try titleLink.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let author = try card.select("a[href^='/author']").first()?.text() ?? "Unknown"
                let reader = try card.select("a[href^='/reader']").first()?.text() ?? ""
                let series = try card.select("a[href^='/serie']").first()?.text() ?? ""
                let previewRaw = try card.select("img._76d12c").first()?.attr("src") ?? ""
                let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)

                output.append(
                    makePreview(
                        author: author,
                        name: title,
                        url: DriverParsing.absoluteURL(host: siteURL, path: urlPath),
                        driver: self.name,
                        reader: reader,
                        duration: "",
                        series: series,
                        number: "",
                        preview: preview
                    )
                )
            }

            remainingOffset = 0
            page += 1
        }
        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] { [] }
}

public struct YaknigaDriver: DriverProtocol {
    public let name = "Yakniga"
    public let siteURL = "https://yakniga.org"
    public let isLicensed = false
    public let isAuthenticated = true

    public init() {}

    public func canHandle(url: String) -> Bool { url.hasPrefix(siteURL) }
    public func getBook(url: String) async throws -> Book {
        let parts = URL(string: url)?.pathComponents.filter { $0 != "/" } ?? []
        guard parts.count >= 2 else { throw CloneError.noSuitableDriver }
        let authorAlias = parts[0]
        let bookAlias = parts[1]

        let payload: [String: Any] = [
            "operationName": "getBook",
            "variables": ["bookAlias": bookAlias, "authorAliasName": authorAlias],
            "query": "query getBook($bookAlias: String, $authorAliasName: String) { book(aliasName: $bookAlias, authorAliasName: $authorAliasName) { title authorName readers { name } seriesName seriesNum duration cover description authorAlias aliasName isBiblio chapters { collection { name duration fileUrl } } } }"
        ]
        let data = try await DriverHTTP.postJSON("\(siteURL)/graphql", jsonObject: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = root["data"] as? [String: Any],
              let book = d["book"] as? [String: Any]
        else {
            throw CloneError.connectionIssue("Invalid Yakniga response")
        }

        if (book["isBiblio"] as? Bool) == true {
            throw CloneError.notAuthenticated
        }

        let title = (book["title"] as? String) ?? ""
        let author = (book["authorName"] as? String) ?? "Unknown"
        let readers = (book["readers"] as? [[String: Any]]) ?? []
        let reader = (readers.first?["name"] as? String) ?? ""
        let seriesName = (book["seriesName"] as? String) ?? ""
        let seriesNumRaw = (book["seriesNum"] as? Double) ?? 0
        let numberInSeries = seriesNumRaw > 0 ? (Double(Int(seriesNumRaw)) == seriesNumRaw ? String(Int(seriesNumRaw)) : String(seriesNumRaw)) : ""
        let duration = DriverParsing.durationFromSeconds((book["duration"] as? Int) ?? 0)
        let cover = (book["cover"] as? String) ?? ""
        let preview = cover.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: cover)
        let descriptionHTML = (book["description"] as? String) ?? ""
        let description: String
        if descriptionHTML.isEmpty {
            description = ""
        } else {
            description = (try? SwiftSoup.parse(descriptionHTML).text()) ?? descriptionHTML
        }

        var items: [BookItem] = []
        if let chapters = book["chapters"] as? [String: Any],
           let collection = chapters["collection"] as? [[String: Any]] {
            for (i, chapter) in collection.enumerated() {
                let cTitle = (chapter["name"] as? String) ?? "Chapter \(i + 1)"
                let end = (chapter["duration"] as? Int) ?? 1
                let path = (chapter["fileUrl"] as? String) ?? ""
                items.append(
                    BookItem(
                        fileURL: DriverParsing.absoluteURL(host: siteURL, path: path),
                        fileIndex: i,
                        title: cTitle,
                        startTime: 0,
                        endTime: max(1, end)
                    )
                )
            }
        }

        return Book(
            id: abs(url.hashValue),
            author: author,
            name: title,
            seriesName: seriesName,
            numberInSeries: numberInSeries,
            description: description,
            reader: reader,
            duration: duration,
            url: url,
            preview: preview,
            driver: self.name,
            items: items
        )
    }

    public func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview] {
        guard query.count >= 3 else { return [] }

        let payload: [String: Any] = [
            "operationName": NSNull(),
            "variables": ["term": query],
            "query": "query ($term: String!) { search(autocomplete: true, term: $term) { ... on Book { title authorName readers { name } seriesName seriesNum duration cover description authorAlias aliasName isBiblio } } }"
        ]
        let data = try await DriverHTTP.postJSON("\(siteURL)/graphql", jsonObject: payload)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let books = dataNode["search"] as? [[String: Any]]
        else {
            return []
        }

        var output: [BookPreview] = []
        var skipped = 0
        for book in books {
            if output.count >= limit { break }
            if skipped < offset {
                skipped += 1
                continue
            }
            if (book["isBiblio"] as? Bool) == true { continue }

            guard let title = book["title"] as? String,
                  let authorAlias = book["authorAlias"] as? String,
                  let aliasName = book["aliasName"] as? String
            else {
                continue
            }

            let author = (book["authorName"] as? String) ?? "Unknown"
            let readers = (book["readers"] as? [[String: Any]]) ?? []
            let reader = (readers.first?["name"] as? String) ?? ""
            let series = (book["seriesName"] as? String) ?? ""
            let seriesNum: String
            if let n = book["seriesNum"] as? Double, n > 0 {
                if Double(Int(n)) == n {
                    seriesNum = String(Int(n))
                } else {
                    seriesNum = String(n)
                }
            } else {
                seriesNum = ""
            }
            let durationSec = (book["duration"] as? Int) ?? 0
            let coverPath = (book["cover"] as? String) ?? ""
            let preview = coverPath.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: coverPath)

            output.append(
                makePreview(
                    author: author,
                    name: title,
                    url: "\(siteURL)/\(authorAlias)/\(aliasName)",
                    driver: self.name,
                    reader: reader,
                    duration: DriverParsing.durationFromSeconds(durationSec),
                    series: series,
                    number: seriesNum,
                    preview: preview
                )
            )
        }

        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] { [] }
}

public struct LibriVoxDriver: DriverProtocol {
    public let name = "LibriVox"
    public let siteURL = "https://archive.org"
    public let isLicensed = false
    public let isAuthenticated = true

    public init() {}

    public func canHandle(url: String) -> Bool { url.hasPrefix(siteURL) }

    private func firstString(_ raw: Any?) -> String? {
        if let value = raw as? String, !value.isEmpty {
            return value
        }
        if let values = raw as? [String], let first = values.first, !first.isEmpty {
            return first
        }
        return nil
    }

    public func getBook(url: String) async throws -> Book {
        guard let identifier = URL(string: url)?.lastPathComponent, !identifier.isEmpty else {
            throw CloneError.noSuitableDriver
        }

        let metadataURL = "\(siteURL)/metadata/\(identifier)"
        let dataString = try await DriverHTTP.getString(metadataURL)
        guard let data = dataString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let files = root["files"] as? [[String: Any]]
        else {
            throw CloneError.connectionIssue("Invalid LibriVox metadata")
        }

        let author = firstString(metadata["creator"]) ?? "Unknown"
        let title = firstString(metadata["title"]) ?? ""
        let duration = firstString(metadata["runtime"]) ?? ""
        let descriptionHTML = firstString(metadata["description"]) ?? ""
        let description = (try? SwiftSoup.parse(descriptionHTML).text()) ?? descriptionHTML

        let previewFile = files.first { ($0["format"] as? String) == "JPEG" }?["name"] as? String
        let preview = previewFile.map { "\(siteURL)/download/\(identifier)/\($0)" } ?? ""

        var items: [BookItem] = []
        var index = 0
        for file in files {
            let format = (file["format"] as? String) ?? ""
            guard format.localizedCaseInsensitiveContains("mp3") else { continue }
            guard let fileName = file["name"] as? String else { continue }
            let chapterTitle = (file["title"] as? String) ?? "Chapter \(index + 1)"
            let lengthString = (file["length"] as? String) ?? "0"
            let end = Int((Double(lengthString) ?? 0).rounded(.down))
            items.append(
                BookItem(
                    fileURL: "\(siteURL)/download/\(identifier)/\(fileName)",
                    fileIndex: index,
                    title: chapterTitle,
                    startTime: 0,
                    endTime: max(1, end)
                )
            )
            index += 1
        }

        return Book(
            id: abs(url.hashValue),
            author: author,
            name: title,
            seriesName: "",
            numberInSeries: "",
            description: description,
            reader: "",
            duration: duration,
            url: url,
            preview: preview,
            driver: self.name,
            items: items
        )
    }

    public func searchBooks(query: String, limit: Int, offset: Int) async throws -> [BookPreview] {
        guard query.count >= 3 else { return [] }
        var output: [BookPreview] = []
        var pageNumber = 1
        var remainingOffset = offset
        let encoded = DriverHTTP.encodedQuery(query.lowercased())

        while output.count < limit {
            let url = "\(siteURL)/advancedsearch.php?q=title:(\(encoded))*+AND+mediatype:audio&fl[]=creator&fl[]=identifier&fl[]=title&rows=\(limit)&page=\(pageNumber)&output=json"
            let dataString = try await DriverHTTP.getString(url)
            guard let data = dataString.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = root["response"] as? [String: Any],
                  var docs = response["docs"] as? [[String: Any]]
            else {
                break
            }

            if docs.isEmpty {
                break
            }

            if remainingOffset > 0 {
                if remainingOffset >= docs.count {
                    remainingOffset -= docs.count
                    pageNumber += 1
                    continue
                }
                docs = Array(docs.dropFirst(remainingOffset))
                remainingOffset = 0
            }

            for item in docs {
                if output.count >= limit {
                    break
                }
                guard let identifier = item["identifier"] as? String else { continue }
                let title = firstString(item["title"]) ?? ""
                let author = firstString(item["creator"]) ?? "Unknown"

                output.append(
                    makePreview(
                        author: author,
                        name: title,
                        url: "\(siteURL)/details/\(identifier)",
                        driver: self.name,
                        reader: "",
                        duration: "",
                        series: "",
                        number: "",
                        preview: "\(siteURL)/services/img/\(identifier)"
                    )
                )
            }

            pageNumber += 1
        }

        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] { [] }
}

private func extractJSONObject(from text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return nil
    }
    let ns = text as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
        return nil
    }
    let jsonRange = match.range(at: 1)
    guard jsonRange.location != NSNotFound else { return nil }
    return ns.substring(with: jsonRange)
}

private func extractJSONArray(from text: String, pattern: String) -> String? {
    extractJSONObject(from: text, pattern: pattern)
}
