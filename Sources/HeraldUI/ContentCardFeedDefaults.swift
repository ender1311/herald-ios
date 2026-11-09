import Foundation
import HeraldSDK

public enum ContentCardFeedDefaults {
    /// Pinned cards first, then newest first.
    public static func order(_ a: ContentCard, _ b: ContentCard) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.createdAt > b.createdAt
    }

    /// Filters, then sorts with a stable sort (equal cards keep server order).
    static func feedCards(
        _ cards: [ContentCard], filter: (ContentCard) -> Bool, order: (ContentCard, ContentCard) -> Bool
    ) -> [ContentCard] {
        cards.filter(filter).enumerated().sorted { lhs, rhs in
            if order(lhs.element, rhs.element) { return true }
            if order(rhs.element, lhs.element) { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// A card counts as seen when at least half of it is on screen.
    static func isImpression(visibleHeight: CGFloat, fullHeight: CGFloat) -> Bool {
        fullHeight > 0 && visibleHeight / fullHeight >= 0.5
    }

    /// VoiceOver label for an image-only card: its title, else `extras["alt"]`.
    static func imageDescription(_ card: ContentCard) -> String? {
        if let title = card.title, !title.isEmpty { return title }
        if case .string(let alt)? = card.extras["alt"], !alt.isEmpty { return alt }
        return nil
    }
}
