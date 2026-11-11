import Foundation

enum PushToken {
    /// APNs device token as lowercase hex, the form APNs and Herald expect.
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

enum PushEnvironment {
    /// "sandbox" for simulator and development-signed builds, "production" otherwise (App Store and
    /// TestFlight builds carry no embedded provisioning profile).
    static let current: String = detect()

    private static func detect() -> String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .isoLatin1)
        else { return "production" }
        return apsEnvironment(inProfile: text) == "development" ? "sandbox" : "production"
        #endif
    }

    /// The `aps-environment` entitlement from the plist embedded in a provisioning profile.
    static func apsEnvironment(inProfile text: String) -> String? {
        guard let key = text.range(of: "<key>aps-environment</key>") else { return nil }
        let rest = text[key.upperBound...]
        guard let open = rest.range(of: "<string>"), let close = rest.range(of: "</string>", range: open.upperBound..<rest.endIndex)
        else { return nil }
        return rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fields Herald reads from an APNs payload. Sent today by src/lib/esp/providers/apns.ts:
/// `nexus_decision_id`, `deeplink` (and `image_url`, read by HeraldNotificationService). Optional keys the
/// Android SDK also reads, for senders that add them: `herald_message_id` and `herald_actions` (up to 3
/// buttons, `[{"id","title","deeplink"?}]`, as a JSON array or a JSON string).
struct HeraldPushPayload: Equatable {
    static let decisionKey = "nexus_decision_id"  // legacy key, kept by the server for compatibility
    static let messageKey = "herald_message_id"
    static let actionsKey = "herald_actions"
    static let maxActions = 3

    struct Action: Equatable {
        let id: String
        let title: String
        let deeplink: URL?
    }

    let decisionId: String?
    let messageId: String?
    let deeplink: URL?
    let actions: [Action]

    /// Nil when the push is not from Herald (neither a decision id nor a message id), or is a sync push.
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo[Herald.syncKey] as? String != "1" else { return nil }
        decisionId = Self.nonEmpty(userInfo[Self.decisionKey])
        messageId = Self.nonEmpty(userInfo[Self.messageKey])
        guard decisionId != nil || messageId != nil else { return nil }
        deeplink = Self.nonEmpty(userInfo["deeplink"]).flatMap(URL.init(string:))
        actions = Self.actions(userInfo[Self.actionsKey])
    }

    /// The id interactions are logged under: the message id, else the decision id.
    var interactionId: String { messageId ?? decisionId ?? "" }

    /// The deep link for a tap: the button's own link when it has one, else the push's.
    func deeplink(forAction identifier: String?) -> URL? {
        actions.first { $0.id == identifier }?.deeplink ?? deeplink
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Malformed entries are skipped; at most `maxActions` are kept.
    static func actions(_ value: Any?) -> [Action] {
        var raw = value
        if let text = value as? String, let data = text.data(using: .utf8) {
            raw = try? JSONSerialization.jsonObject(with: data)
        }
        guard let items = raw as? [Any] else { return [] }
        let parsed = items.compactMap { item -> Action? in
            guard let object = item as? [String: Any], let id = nonEmpty(object["id"]), let title = nonEmpty(object["title"])
            else { return nil }
            return Action(id: id, title: title, deeplink: nonEmpty(object["deeplink"]).flatMap(URL.init(string:)))
        }
        return Array(parsed.prefix(maxActions))
    }
}
