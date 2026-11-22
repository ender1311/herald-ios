import Foundation

/// The kind of push your app sent itself, reported with `Herald.trackExternalPush`.
public enum ExternalPushCategory: String, Sendable {
    case transactional, marketing, other
}

/// `$external_push`: a push the app sent itself (not through Herald), so Herald's push limit can count it.
enum ExternalPush {
    static let eventName = "$external_push"
    /// Payload keys a sender can add: the id its backend reports, and the category.
    /// (`herald_message_id` is the key Herald's own pushes carry, so it can't be reused here.)
    static let messageIdKey = "herald_external_id"
    static let categoryKey = "herald_category"
    static let maxMessageId = 200
    static let maxSource = 100

    static let tooLong = "messageId must be at most \(maxMessageId) characters and source at most \(maxSource)"

    /// The event's properties; nil when `messageId` or `source` is too long (the server would refuse the batch).
    static func properties(messageId: String?, category: ExternalPushCategory, source: String?) -> [String: HeraldValue]? {
        var props: [String: HeraldValue] = ["category": .string(category.rawValue)]
        if let id = messageId, !id.isEmpty {
            guard id.utf16.count <= maxMessageId else { return nil }
            props["message_id"] = .string(id)
        }
        if let source, !source.isEmpty {
            guard source.utf16.count <= maxSource else { return nil }
            props["source"] = .string(source)
        }
        return props
    }

    /// What auto-capture records for a push shown or tapped: nil for a Herald push, a Herald sync push, a silent
    /// push (no `aps.alert`) and a local notification (no `aps`). The id is `herald_external_id`, else the request id.
    static func capture(userInfo: [AnyHashable: Any], requestIdentifier: String?) -> (messageId: String?, category: ExternalPushCategory)? {
        guard HeraldPushPayload(userInfo: userInfo) == nil, userInfo[Herald.syncKey] as? String != "1" else { return nil }
        guard let aps = userInfo["aps"] as? [String: Any], hasAlert(aps["alert"]) else { return nil }
        let own = (userInfo[messageIdKey] as? String).flatMap { (1...maxMessageId).contains($0.utf16.count) ? $0 : nil }
        let category = (userInfo[categoryKey] as? String).flatMap(ExternalPushCategory.init(rawValue:)) ?? .other
        return (own ?? requestIdentifier, category)
    }

    private static func hasAlert(_ alert: Any?) -> Bool {
        if let text = alert as? String { return !text.isEmpty }
        if let fields = alert as? [String: Any] { return !fields.isEmpty }
        return false
    }
}
