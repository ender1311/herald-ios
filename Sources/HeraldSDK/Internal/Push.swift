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

/// Fields Herald puts in its APNs payload (src/lib/esp/providers/apns.ts).
struct HeraldPushPayload: Equatable {
    static let decisionKey = "nexus_decision_id"  // legacy key, kept by the server for compatibility

    let decisionId: String
    let deeplink: URL?

    init?(userInfo: [AnyHashable: Any]) {
        guard let decisionId = userInfo[Self.decisionKey] as? String, !decisionId.isEmpty else { return nil }
        self.decisionId = decisionId
        deeplink = (userInfo["deeplink"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}
