import Foundation

/// The app's remote SDK settings (`GET /api/v1/sdk/config`), cached on disk and laid over the app's configuration.
struct RemoteConfig: Equatable {
    var version: String
    var settings: [String: HeraldValue]

    /// A 200 body, `{ "data": { "version": …, "settings": { … } } }`; nil when unreadable.
    static func decode(_ data: Data) -> RemoteConfig? {
        guard let body = (try? JSONDecoder().decode(HeraldValue.self, from: data))?.objectValue?["data"]?.objectValue,
            let version = body["version"]?.stringValue
        else { return nil }
        return RemoteConfig(version: version, settings: body["settings"]?.objectValue ?? [:])
    }

    /// The kill switch: `enabled: false` stops collection and sending.
    var collects: Bool { settings["enabled"]?.boolValue ?? true }

    /// Remote values over the app's own; a missing or mistyped value keeps the app's.
    func applied(to local: HeraldConfiguration) -> HeraldConfiguration {
        var c = local
        let number = { (key: String) in settings[key]?.numberValue }
        if let v = number("flushIntervalSeconds") { c.flushInterval = v }
        if let v = number("foregroundSessionTimeoutSeconds") { c.foregroundSessionTimeout = v }
        if let v = number("backgroundSessionTimeoutSeconds") { c.backgroundSessionTimeout = v }
        if let v = settings["dataCollection"]?.stringValue.flatMap(DeviceDataCollection.init(rawValue:)) {
            c.deviceDataCollection = v
        }
        if let v = settings["trackLifecycleEvents"]?.boolValue { c.trackLifecycleEvents = v }
        if let v = settings["trackExternalPushes"]?.boolValue { c.trackExternalPushes = v }
        if let v = settings["trackDeepLinks"]?.boolValue { c.trackDeepLinks = v }
        return c
    }
}
