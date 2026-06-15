import Foundation

enum DriverHTTP {
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static func getString(
        _ urlString: String,
        headers: [String: String] = [:]
    ) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw CloneError.connectionIssue("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloneError.connectionIssue("HTTP error on \(urlString)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func postJSON(
        _ urlString: String,
        jsonObject: Any,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw CloneError.connectionIssue("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloneError.connectionIssue("HTTP error on \(urlString)")
        }
        return data
    }

    static func getData(
        _ urlString: String,
        headers: [String: String] = [:]
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw CloneError.connectionIssue("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CloneError.connectionIssue("HTTP error on \(urlString)")
        }
        return data
    }

    static func encodedQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }
}

enum DriverParsing {
    static func parseSeries(_ value: String) -> (String, String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "^(.+?)\\s*\\((\\d+)\\)$") else {
            return (trimmed, "")
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let nameRange = Range(match.range(at: 1), in: trimmed),
              let numberRange = Range(match.range(at: 2), in: trimmed)
        else {
            return (trimmed, "")
        }
        return (String(trimmed[nameRange]), String(trimmed[numberRange]))
    }

    static func durationFromSeconds(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func absoluteURL(host: String, path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        if path.hasPrefix("/") {
            return host + path
        }
        return host + "/" + path
    }
}
