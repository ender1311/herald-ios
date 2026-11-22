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
    /// Seconds of inactivity in the foreground after which the next activity starts a new session. A cold start
    /// within this time of the last activity continues the session.
    public var foregroundSessionTimeout: TimeInterval = 30 * 60
    /// Seconds in the background after which the next activity starts a new session.
    public var backgroundSessionTimeout: TimeInterval = 30 * 60
    /// Sets both `foregroundSessionTimeout` and `backgroundSessionTimeout`; reads the foreground one.
    @available(*, deprecated, message: "Use foregroundSessionTimeout and backgroundSessionTimeout")
    public var sessionTimeout: TimeInterval {
        get { foregroundSessionTimeout }
        set {
            foregroundSessionTimeout = newValue
            backgroundSessionTimeout = newValue
        }
    }
    /// Sends `$app_installed`, `$app_updated`, `$app_opened`, `$app_foreground` and `$app_background`.
    public var trackLifecycleEvents: Bool = true
    /// Sends `$deep_link_opened` when a deep link goes through the SDK (push taps and `openDeepLink`).
    public var trackDeepLinks: Bool = true
    /// Adds the deep link's query string to `$deep_link_opened` (off: it can hold personal data).
    public var trackDeepLinkQuery: Bool = false
    /// Queued events older than this (seconds) are dropped before a batch is built and counted in `dropped`;
    /// Herald rejects SDK events more than 30 days old.
    public var maxQueuedEventAge: TimeInterval = 30 * 86_400
    /// Minimum seconds between two triggered in-app messages.
    public var inAppMinimumInterval: TimeInterval = 30
    public var logLevel: HeraldLogLevel = .warning
    /// iOS only: sends MetricKit crash and hang diagnostics to Herald, with no user or device id.
    /// Nothing is sent while the SDK is disabled.
    public var crashReports: Bool = false
    /// Records a push your app sent itself (not from Herald) as `$external_push` when it is tapped, so Herald's
    /// push limit counts it. Silent pushes and local notifications are never recorded.
    public var trackExternalPushes: Bool = true

    public init(appKey: String, endpoint: URL) {
        self.appKey = appKey
        self.endpoint = endpoint
    }
}
