import Foundation

public struct DownloadTaskInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case mp3
        case m3u8
        case mergedM3U8
    }

    public enum DescriptionLanguage: Sendable, Equatable {
        case en
        case ru
    }

    public let bid: Int
    public let title: String
    public let destinationRoot: String
    public let book: Book
    public let urls: [String]
    public let kind: Kind
    public let descriptionLanguage: DescriptionLanguage

    public init(
        bid: Int,
        title: String,
        destinationRoot: String,
        book: Book,
        urls: [String],
        kind: Kind,
        descriptionLanguage: DescriptionLanguage
    ) {
        self.bid = bid
        self.title = title
        self.destinationRoot = destinationRoot
        self.book = book
        self.urls = urls
        self.kind = kind
        self.descriptionLanguage = descriptionLanguage
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public let bid: Int
    public let status: DownloadEntry.Status
    public let percent: Double
    public let doneSize: String
    public let totalSize: String
    public let stage: String
    public let errorMessage: String

    public init(
        bid: Int,
        status: DownloadEntry.Status,
        percent: Double,
        doneSize: String,
        totalSize: String,
        stage: String = "",
        errorMessage: String = ""
    ) {
        self.bid = bid
        self.status = status
        self.percent = percent
        self.doneSize = doneSize
        self.totalSize = totalSize
        self.stage = stage
        self.errorMessage = errorMessage
    }
}
