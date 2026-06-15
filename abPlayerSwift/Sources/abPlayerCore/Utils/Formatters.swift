import Foundation

public enum Formatters {
    private static let addingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func addingDate(_ date: Date) -> String {
        addingDateFormatter.string(from: date)
    }
}
