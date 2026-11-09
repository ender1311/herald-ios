import Foundation

/// How much device data the SDK collects automatically.
public enum DeviceDataCollection: String, Sendable {
    /// Tier 1 and tier 2: adds time zone, locale, language, device model, screen, push permission and network type.
    case standard
    /// Tier 1 only: device id, app, OS, SDK version, region, sessions and message interactions.
    case minimal
}

public enum HeraldLogLevel: Int, Sendable, Comparable {
    case none = 0, error, warning, info, debug

    public static func < (lhs: HeraldLogLevel, rhs: HeraldLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SubscriptionChannel: String, Sendable, Codable {
    case push, email, sms
}

public enum SubscriptionState: String, Sendable, Codable {
    case subscribed
    case unsubscribed
    case optedIn = "opted_in"
}

/// Settings passed to `Herald.configure`. Defaults follow the published SDK behavior.
public struct HeraldConfiguration: Sendable {
    /// The connection's publishable key, sent as `x-herald-app-key`.
    public var appKey: String
    /// Base URL of the Herald API, for example `https://herald.example.com`.
    public var endpoint: URL
    public var deviceDataCollection: DeviceDataCollection = .standard
    /// Seconds between automatic flushes while the app is in the foreground.
    public var flushInterval: TimeInterval = 10
    /// Queued event count that triggers an immediate flush.
    public var flushAt: Int = 20
    /// Seconds of inactivity after which the next activity starts a new session.
    public var sessionTimeout: TimeInterval = 30 * 60
    /// Minimum seconds between two triggered in-app messages.
    public var inAppMinimumInterval: TimeInterval = 30
    public var logLevel: HeraldLogLevel = .warning

    public init(appKey: String, endpoint: URL) {
        self.appKey = appKey
        self.endpoint = endpoint
    }
}
