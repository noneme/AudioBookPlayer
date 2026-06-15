import Foundation

public struct DriverRegistry: Sendable {
    public let drivers: [DriverProtocol]

    public init(drivers: [DriverProtocol]) {
        self.drivers = drivers
    }

    public init(bookmateAuthToken: String) {
        self.drivers = [
            KnigaVUheDriver(),
            AKnigaDriver(),
            IzibukDriver(),
            YaknigaDriver(),
            LibriVoxDriver(),
            BookmateDriver(authToken: bookmateAuthToken)
        ]
    }

    public static func `default`() -> DriverRegistry {
        let token = UserDefaults.standard.string(forKey: AppSettingsKeys.bookmateAuthToken) ?? ""
        return DriverRegistry(bookmateAuthToken: token)
    }
}
