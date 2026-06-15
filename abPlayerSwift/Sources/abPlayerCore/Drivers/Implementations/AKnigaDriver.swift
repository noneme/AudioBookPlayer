import Foundation
import SwiftSoup

private func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? Double { return Int(value) }
    if let value = raw as? String, let parsed = Int(value) { return parsed }
    return nil
}

private func parseAKnigaChapters(rawItems: String, fileURL: String) -> [BookItem] {
    guard let data = rawItems.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
        return []
    }

    var output: [BookItem] = []
    for (index, row) in raw.enumerated() {
        let title = (row["title"] as? String) ?? "Chapter \(index + 1)"
        let start = intValue(row["time_from_start"]) ?? 0
        let end = intValue(row["time_finish"]) ?? max(1, start + (intValue(row["duration"]) ?? 1))
        output.append(BookItem(
            fileURL: fileURL,
            fileIndex: index,
            title: title,
            startTime: start,
            endTime: max(start + 1, end)
        ))
    }
    return output
}

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

private func extractAKnigaDescription(from doc: Document) throws -> String {
    for block in try doc.select("div.description__article-main").array() {
        let caption = try block.select("div.content__main__book--item--caption").first()?.text()
        if caption?.lowercased().contains("описан") != true {
            continue
        }

        var blockText = try block.text()
        if let caption, !caption.isEmpty {
            if blockText.hasPrefix(caption) {
                blockText.removeFirst(caption.count)
            } else {
                blockText = blockText.replacingOccurrences(of: caption, with: "")
            }
        }
        if let normalized = normalizedDescriptionCandidate(blockText) {
            return normalized
        }
    }

    let itemprop = try doc.select("[itemprop='description']").first()?.text()
    let og = try doc.select("meta[property='og:description']").first()?.attr("content")
    let meta = try doc.select("meta[name='description']").first()?.attr("content")
    return firstNormalizedDescription([itemprop, og, meta])
}

public struct AKnigaDriver: DriverProtocol {
    public let name = "AKniga"
    public let siteURL = "https://akniga.org"
    public let isLicensed = false
    public let isAuthenticated = true

    private let decryptor: AKnigaDecrypting

    public init(decryptor: AKnigaDecrypting = AKnigaCompositeDecryptor()) {
        self.decryptor = decryptor
    }

    public func canHandle(url: String) -> Bool {
        url.hasPrefix(siteURL)
    }

    public func getBook(url: String) async throws -> Book {
        let html = try await DriverHTTP.getString(url)
        let doc = try SwiftSoup.parse(html)

        let parsedTitle = try doc.select("h1.caption__article-main").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = try doc.title()
        let title = parsedTitle ?? fallbackTitle

        var author = try doc.select("span.link__action--author a[href*='author']").first()?.text() ?? ""
        let reader = try doc.select("a.link__reader span").first()?.text() ?? ""
        let previewRaw = try doc.select("div.book--cover img").first()?.attr("src") ?? ""
        let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)
        let description = try extractAKnigaDescription(from: doc)

        var seriesName = ""
        var numberInSeries = ""
        if let seriesRaw = try doc.select("div.content__main__book--item--series-list > a.current").first()?.text(), !seriesRaw.isEmpty {
            let parsed = DriverParsing.parseSeries(seriesRaw.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
            seriesName = parsed.0
            numberInSeries = parsed.1
        }

        var duration = ""
        let durationPieces = try doc.select("span[class*='book-duration-'] > span").array().map { try $0.text() }
        if !durationPieces.isEmpty {
            duration = durationPieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var items: [BookItem] = []
        if let securityKey = extractAKnigaSecurityKey(from: html),
           let bid = extractAKnigaBid(from: html),
           let token = try await fetchAKnigaToken(securityKey: securityKey, bid: bid, referer: url),
           let response = try await fetchAKnigaBookData(securityKey: securityKey, bid: bid, token: token, referer: url),
           let hresRaw = response["hres"] as? String,
           let decrypted = try decryptor.decrypt(hres: hresRaw, securityKey: securityKey),
           let m3u8URL = extractAKnigaURL(fromDecrypted: decrypted),
           let rawItems = response["items"] as? String {
            if let apiAuthor = response["author"] as? String,
               !apiAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                author = apiAuthor
            }
            items = parseAKnigaChapters(rawItems: rawItems, fileURL: m3u8URL)
        }

        if author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            author = "Unknown"
        }

        if items.isEmpty {
            throw CloneError.connectionIssue("AKniga: failed to parse stream URL or chapters")
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
        var pageNumber = 1
        var remainingOffset = offset

        while output.count < limit {
            let html = try await DriverHTTP.getString("\(siteURL)/search/books/page\(pageNumber)/?q=\(encoded)")
            let doc = try SwiftSoup.parse(html)
            let cards = try doc.select("div.content__main__articles--item")
            let cardArray = cards.array()

            if cardArray.isEmpty { break }
            if remainingOffset >= cardArray.count {
                remainingOffset -= cardArray.count
                pageNumber += 1
                continue
            }

            for card in cardArray.dropFirst(remainingOffset) {
                if output.count >= limit { break }

                guard let anchor = try card.select("div.article--cover > a").first() else {
                    continue
                }

                let urlPath = try anchor.attr("href")
                let url = DriverParsing.absoluteURL(host: siteURL, path: urlPath)
                let previewRaw = try card.select("div.article--cover > a img").first()?.attr("src") ?? ""
                let preview = previewRaw.isEmpty ? "" : DriverParsing.absoluteURL(host: siteURL, path: previewRaw)
                let author = try card.select("span.link__action--author a[href*='author']").first()?.text() ?? "Unknown"

                let rawNameFromImg = try card.select("div.article--cover > a img").first()?.attr("alt")
                let rawNameFromCaption = try card.select(".caption__article-main").first()?.text()
                let rawName = rawNameFromImg ?? rawNameFromCaption ?? ""
                let name = rawName.replacingOccurrences(of: "\(author) – ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

                let reader = try card.select("span.link__action--author a[href*='performer']").first()?.text() ?? ""
                let duration = try card.select("span.link__action--label--time").first()?.text() ?? ""

                var seriesName = ""
                var numberInSeries = ""
                if let seriesRaw = try card.select("span.link__action--author a[href*='series']").last()?.text(), !seriesRaw.isEmpty {
                    let parsed = DriverParsing.parseSeries(seriesRaw)
                    seriesName = parsed.0
                    numberInSeries = parsed.1
                }

                output.append(
                    BookPreview(
                        author: author,
                        name: name,
                        seriesName: seriesName,
                        numberInSeries: numberInSeries,
                        reader: reader,
                        duration: duration,
                        url: url,
                        preview: preview,
                        driver: self.name
                    )
                )
            }

            remainingOffset = 0
            pageNumber += 1
        }

        return output
    }

    public func getBookSeries(url: String) async throws -> [BookPreview] {
        let _ = try? decryptor.decrypt(hres: "invalid", securityKey: "demo")
        return []
    }
}

private func extractAKnigaSecurityKey(from html: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: #"LIVESTREET_SECURITY_KEY\s*=\s*'(.+?)'"#) else {
        return nil
    }
    let ns = html as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: html, options: [], range: range), match.numberOfRanges > 1 else {
        return nil
    }
    return ns.substring(with: match.range(at: 1))
}

private func extractAKnigaBid(from html: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: #"data-bid=\"(\d+)\""#) else {
        return nil
    }
    let ns = html as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: html, options: [], range: range), match.numberOfRanges > 1 else {
        return nil
    }
    return ns.substring(with: match.range(at: 1))
}

private func extractAKnigaURL(fromDecrypted decrypted: String?) -> String? {
    guard let decrypted else { return nil }
    let trimmed = decrypted.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("http") {
        return trimmed
    }

    if trimmed.hasPrefix("\"") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let direct = json as? String, direct.hasPrefix("http") {
                return direct
            }
            if let dict = json as? [String: Any] {
                if let url = dict["url"] as? String, url.hasPrefix("http") {
                    return url
                }
                if let data = dict["data"] as? String, data.hasPrefix("http") {
                    return data
                }
            }
        }
    }
    return nil
}

private func fetchAKnigaToken(securityKey: String, bid: String, referer: String) async throws -> String? {
    guard let url = URL(string: "https://akniga.org/ajax/player/token") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(DriverHTTP.defaultUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue("https://akniga.org", forHTTPHeaderField: "Origin")
    request.setValue(referer, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
    request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")

    let bodyItems = [
        URLQueryItem(name: "security_ls_key", value: securityKey),
        URLQueryItem(name: "bid", value: bid),
        URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))
    ]
    var comps = URLComponents()
    comps.queryItems = bodyItems
    request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
        return nil
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json["token"] as? String
}

private func fetchAKnigaBookData(securityKey: String, bid: String, token: String, referer: String) async throws -> [String: Any]? {
    guard let url = URL(string: "https://akniga.org/ajax/b/\(bid)") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(DriverHTTP.defaultUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue("https://akniga.org", forHTTPHeaderField: "Origin")
    request.setValue(referer, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
    request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")

    let bodyItems = [
        URLQueryItem(name: "security_ls_key", value: securityKey),
        URLQueryItem(name: "bid", value: bid),
        URLQueryItem(name: "token", value: token),
        URLQueryItem(name: "hls", value: "1")
    ]
    var comps = URLComponents()
    comps.queryItems = bodyItems
    request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
        return nil
    }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
