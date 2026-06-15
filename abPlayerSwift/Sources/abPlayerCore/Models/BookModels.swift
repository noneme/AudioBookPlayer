import Foundation

public enum BookStatus: String, Codable, Sendable {
    case new
    case started
    case finished
}

public struct StopFlag: Codable, Sendable, Equatable {
    public var item: Int
    public var time: Int

    public init(item: Int = 0, time: Int = 0) {
        self.item = item
        self.time = time
    }
}

public struct BookItem: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { fileIndex }
    public let fileURL: String
    public let fileIndex: Int
    public let title: String
    public let startTime: Int
    public let endTime: Int

    public init(fileURL: String, fileIndex: Int, title: String, startTime: Int, endTime: Int) {
        self.fileURL = fileURL
        self.fileIndex = fileIndex
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
    }

    public var duration: Int {
        max(0, endTime - startTime)
    }
}

public struct Book: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var author: String
    public var name: String
    public var seriesName: String
    public var numberInSeries: String
    public var description: String
    public var reader: String
    public var duration: String
    public var url: String
    public var preview: String
    public var driver: String
    public var items: [BookItem]
    public var status: BookStatus
    public var stopFlag: StopFlag
    public var favorite: Bool
    public var downloaded: Bool
    public var downloading: Bool
    public var addingDate: Date

    public init(
        id: Int,
        author: String,
        name: String,
        seriesName: String = "",
        numberInSeries: String = "",
        description: String = "",
        reader: String = "",
        duration: String = "",
        url: String,
        preview: String = "",
        driver: String = "",
        items: [BookItem] = [],
        status: BookStatus = .new,
        stopFlag: StopFlag = StopFlag(),
        favorite: Bool = false,
        downloaded: Bool = false,
        downloading: Bool = false,
        addingDate: Date = Date()
    ) {
        self.id = id
        self.author = author
        self.name = name
        self.seriesName = seriesName
        self.numberInSeries = numberInSeries
        self.description = description
        self.reader = reader
        self.duration = duration
        self.url = url
        self.preview = preview
        self.driver = driver
        self.items = items
        self.status = status
        self.stopFlag = stopFlag
        self.favorite = favorite
        self.downloaded = downloaded
        self.downloading = downloading
        self.addingDate = addingDate
    }

    public var listeningProgress: String {
        if status == .finished {
            return "100%"
        }
        let total = items.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return "0%" }

        var passed = 0
        for (index, item) in items.enumerated() where index < stopFlag.item {
            passed += item.duration
        }
        passed += stopFlag.time

        let value = Int(round((Double(passed) / Double(total)) * 100.0))
        return "\(value)%"
    }

    public var displaySeries: String {
        guard !seriesName.isEmpty else { return "" }
        if numberInSeries.isEmpty {
            return seriesName
        }
        return "\(seriesName) (\(numberInSeries))"
    }
}

public struct BookPreview: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let author: String
    public let name: String
    public let seriesName: String
    public let numberInSeries: String
    public let reader: String
    public let duration: String
    public let url: String
    public let preview: String
    public let driver: String

    public init(
        author: String,
        name: String,
        seriesName: String = "",
        numberInSeries: String = "",
        reader: String = "",
        duration: String = "",
        url: String,
        preview: String = "",
        driver: String = ""
    ) {
        self.author = author
        self.name = name
        self.seriesName = seriesName
        self.numberInSeries = numberInSeries
        self.reader = reader
        self.duration = duration
        self.url = url
        self.preview = preview
        self.driver = driver
    }

    public var displaySeries: String {
        guard !seriesName.isEmpty else { return "" }
        if numberInSeries.isEmpty {
            return seriesName
        }
        return "\(seriesName) (\(numberInSeries))"
    }
}

public struct DriverInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let licensed: Bool
    public var authed: Bool
    public let url: String

    public init(name: String, licensed: Bool, authed: Bool, url: String) {
        self.name = name
        self.licensed = licensed
        self.authed = authed
        self.url = url
    }
}

public struct DownloadEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case waiting
        case preparing
        case downloading
        case finishing
        case finished
        case terminating
        case terminated
    }

    public var id: Int { bid }
    public let bid: Int
    public let title: String
    public var status: Status
    public var totalSize: String
    public var doneSize: String
    public var progressPercent: Double
    public var stage: String
    public var errorMessage: String

    public init(
        bid: Int,
        title: String,
        status: Status = .waiting,
        totalSize: String = "",
        doneSize: String = "",
        progressPercent: Double = 0,
        stage: String = "",
        errorMessage: String = ""
    ) {
        self.bid = bid
        self.title = title
        self.status = status
        self.totalSize = totalSize
        self.doneSize = doneSize
        self.progressPercent = progressPercent
        self.stage = stage
        self.errorMessage = errorMessage
    }
}
