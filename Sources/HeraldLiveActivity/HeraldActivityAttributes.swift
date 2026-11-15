import Foundation
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// The Live Activity Herald starts with a push-to-start. The server sends `attributes-type`
/// "HeraldActivityAttributes", so the type name and field names are part of the wire format.
public struct HeraldActivityAttributes: Codable, Hashable, Sendable {
    public let campaignId: String
    public let deeplink: String?

    public struct ContentState: Codable, Hashable, Sendable {
        public let title: String
        public let body: String
        /// 0–1, for progress mode.
        public let progress: Double?
        /// Unix seconds, not `Date`: ActivityKit's default decoder would read a `Date` as seconds since 2001.
        public let endsAt: Double?

        public init(title: String, body: String, progress: Double? = nil, endsAt: Double? = nil) {
            self.title = title
            self.body = body
            self.progress = progress
            self.endsAt = endsAt
        }
    }

    public init(campaignId: String, deeplink: String? = nil) {
        self.campaignId = campaignId
        self.deeplink = deeplink
    }
}

// The conformance sits apart from the struct so the Codable shape builds and is tested on macOS,
// where ActivityKit's ActivityAttributes is unavailable.
#if os(iOS) && canImport(ActivityKit)
@available(iOS 16.1, *)
extension HeraldActivityAttributes: ActivityAttributes {}
#endif
