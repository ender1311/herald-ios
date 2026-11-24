import Foundation

/// A content card synced from Herald. Show it in `HeraldUI`'s feed or in your own UI;
/// custom UIs report impressions, clicks and dismissals with `Herald.shared.logImpression(_:)` and friends.
public struct ContentCard: Sendable, Hashable, Identifiable {
    public enum CardType: String, Sendable, Hashable, CaseIterable {
        case classic
        case captionedImage = "captioned_image"
        case imageOnly = "image_only"
    }

    public let id: String
    public let type: CardType
    public let title: String?
    public let body: String?
    public let imageUrl: URL?
    public let cta: String?
    /// Deep link or web URL opened on click.
    public let url: URL?
    public let extras: [String: HeraldValue]
    public let pinned: Bool
    public let dismissible: Bool
    public let categories: [String]
    public let createdAt: Date
    public let expiresAt: Date?
    public var viewed: Bool
    public var clicked: Bool
    public var dismissed: Bool
    /// Herald decision this card came from; sent back with interactions so the outcome is attributed.
    public let decisionId: String?
    /// A video to play in place of the image; `imageUrl` then holds its poster.
    public let videoUrl: URL?
    /// The video's poster (the same as `imageUrl`).
    public let videoPosterUrl: URL?
    /// Play the video muted and looped while the card is on screen (false by default).
    public let videoAutoplay: Bool
    /// Who made the stock photo or video, for apps that show a credit.
    public let credit: MediaCredit?

    public init(
        id: String, type: CardType, title: String? = nil, body: String? = nil, imageUrl: URL? = nil,
        cta: String? = nil, url: URL? = nil, extras: [String: HeraldValue] = [:], pinned: Bool = false,
        dismissible: Bool = true, categories: [String] = [], createdAt: Date = Date(), expiresAt: Date? = nil,
        viewed: Bool = false, clicked: Bool = false, dismissed: Bool = false, decisionId: String? = nil,
        videoUrl: URL? = nil, videoPosterUrl: URL? = nil, videoAutoplay: Bool = false, credit: MediaCredit? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.body = body
        self.imageUrl = imageUrl
        self.cta = cta
        self.url = url
        self.extras = extras
        self.pinned = pinned
        self.dismissible = dismissible
        self.categories = categories
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.viewed = viewed
        self.clicked = clicked
        self.dismissed = dismissed
        self.decisionId = decisionId
        self.videoUrl = videoUrl
        self.videoPosterUrl = videoPosterUrl
        self.videoAutoplay = videoAutoplay
        self.credit = credit
    }

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

extension ContentCard: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, type, title, body, imageUrl, cta, url, extras, pinned, dismissible, categories, createdAt, expiresAt
        case viewed, clicked, dismissed, decisionId, videoUrl, videoPosterUrl, videoAutoplay, credit
    }

    /// Lenient decoding: `id` and a known `type` are required, every other field falls back to a default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let type = CardType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown card type \(rawType)")
        }
        self.init(
            id: try c.decode(String.self, forKey: .id),
            type: type,
            title: c.lenient(String.self, .title),
            body: c.lenient(String.self, .body),
            imageUrl: c.lenientURL(.imageUrl),
            cta: c.lenient(String.self, .cta),
            url: c.lenientURL(.url),
            extras: c.lenient([String: HeraldValue].self, .extras) ?? [:],
            pinned: c.lenient(Bool.self, .pinned) ?? false,
            dismissible: c.lenient(Bool.self, .dismissible) ?? true,
            categories: c.lenient([String].self, .categories) ?? [],
            createdAt: c.lenientDate(.createdAt) ?? .distantPast,
            expiresAt: c.lenientDate(.expiresAt),
            viewed: c.lenient(Bool.self, .viewed) ?? false,
            clicked: c.lenient(Bool.self, .clicked) ?? false,
            dismissed: c.lenient(Bool.self, .dismissed) ?? false,
            decisionId: c.lenient(String.self, .decisionId),
            videoUrl: c.lenientURL(.videoUrl),
            videoPosterUrl: c.lenientURL(.videoPosterUrl),
            videoAutoplay: c.lenient(Bool.self, .videoAutoplay) ?? false,
            credit: c.lenient(MediaCredit.self, .credit)
        )
    }
}

/// The photographer or creator of a stock photo or video, with links that already carry Herald's
/// referral parameters.
public struct MediaCredit: Sendable, Hashable {
    public let name: String
    public let profileUrl: URL?
    /// The photo or video on its provider's site.
    public let sourceUrl: URL?

    public init(name: String, profileUrl: URL? = nil, sourceUrl: URL? = nil) {
        self.name = name
        self.profileUrl = profileUrl
        self.sourceUrl = sourceUrl
    }
}

extension MediaCredit: Decodable {
    private enum CodingKeys: String, CodingKey { case name, profileUrl, sourceUrl }

    /// A credit without a name is dropped (decodes as nil through `lenient`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Credit without a name")
        }
        self.init(name: name, profileUrl: c.lenientURL(.profileUrl), sourceUrl: c.lenientURL(.sourceUrl))
    }
}

extension KeyedDecodingContainer {
    /// Missing, null or wrongly typed values decode as nil instead of failing the whole item.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func lenientURL(_ key: Key) -> URL? {
        guard let string = lenient(String.self, key), !string.isEmpty else { return nil }
        return URL(string: string)
    }

    func lenientDate(_ key: Key) -> Date? {
        lenient(String.self, key).flatMap(WireDate.parse)
    }
}
