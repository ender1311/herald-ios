#if os(iOS)
import HeraldSDK
import SwiftUI

/// The current user's content cards from `Herald.shared.contentCards`, pinned first then newest.
///
/// Impressions are logged once per card when at least half of it is visible. Clicks are logged, then
/// passed to `onCardClick`, or by default the card's url opens through `Herald.shared.deepLinkHandler`
/// and then the environment's `openURL`. Dismissible cards can be swiped away (VoiceOver: the Dismiss
/// action), which logs the dismissal.
///
/// ```swift
/// ContentCardFeed()                                  // default cards
/// ContentCardFeed { card, onClick in                 // replace one type
///     if card.type == .classic { MyCard(card, onClick) } else { ContentCardView(card: card, onClick: onClick) }
/// }
/// ```
public struct ContentCardFeed<CardContent: View>: View {
    private let filter: (ContentCard) -> Bool
    private let order: (ContentCard, ContentCard) -> Bool
    private let emptyMessage: LocalizedStringKey
    private let onCardClick: ((ContentCard) -> Void)?
    private let cardContent: (ContentCard, @escaping () -> Void) -> CardContent

    @ObservedObject private var store = Herald.shared.contentCards
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var impressed: Set<String> = []
    @State private var hidden: Set<String> = []

    private static var space: String { "herald.feed" }

    /// - Parameters:
    ///   - filter: keeps only the cards it returns true for.
    ///   - order: sort order (`areInIncreasingOrder`); pinned first, then newest by default.
    ///   - emptyMessage: shown when there are no cards; looked up in your app's strings.
    ///   - onCardClick: runs after the click is logged, instead of opening the card url.
    ///   - cardContent: draws one card. Call `onClick` when it is tapped.
    public init(
        filter: @escaping (ContentCard) -> Bool = { _ in true },
        order: @escaping (ContentCard, ContentCard) -> Bool = ContentCardFeedDefaults.order,
        emptyMessage: LocalizedStringKey = "No updates right now",
        onCardClick: ((ContentCard) -> Void)? = nil,
        @ViewBuilder cardContent: @escaping (_ card: ContentCard, _ onClick: @escaping () -> Void) -> CardContent
    ) {
        self.filter = filter
        self.order = order
        self.emptyMessage = emptyMessage
        self.onCardClick = onCardClick
        self.cardContent = cardContent
    }

    public var body: some View {
        let colors = theme.colors(for: colorScheme)
        let cards = ContentCardFeedDefaults.feedCards(
            store.cards, filter: { !hidden.contains($0.id) && filter($0) }, order: order
        )
        GeometryReader { viewport in
            Group {
                if cards.isEmpty {
                    Text(emptyMessage)
                        .font(theme.typography.body)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .padding(theme.spacing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(cards) { card in
                            row(card)
                                .listRowInsets(EdgeInsets(
                                    top: theme.spacing * 0.375, leading: theme.spacing,
                                    bottom: theme.spacing * 0.375, trailing: theme.spacing
                                ))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .onPreferenceChange(CardFrameKey.self) { frames in
                logImpressions(frames, viewport: CGRect(origin: .zero, size: viewport.size))
            }
        }
        .coordinateSpace(name: Self.space)
        .background(colors.background)
    }

    @ViewBuilder
    private func row(_ card: ContentCard) -> some View {
        let content = cardContent(card) { click(card) }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: CardFrameKey.self, value: [card.id: geometry.frame(in: .named(Self.space))])
            })
        if card.dismissible {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) { dismiss(card) } label: { Label("Dismiss", systemImage: "xmark") }
            }
        } else {
            content
        }
    }

    private func logImpressions(_ frames: [String: CGRect], viewport: CGRect) {
        for (id, frame) in frames where !impressed.contains(id) {
            let visible = frame.intersection(viewport)
            let height = visible.isNull ? 0 : visible.height
            guard ContentCardFeedDefaults.isImpression(visibleHeight: height, fullHeight: frame.height),
                let card = store.cards.first(where: { $0.id == id })
            else { continue }
            impressed.insert(id)
            Herald.shared.logImpression(card)
        }
    }

    private func click(_ card: ContentCard) {
        Herald.shared.logClick(card)
        if let onCardClick {
            onCardClick(card)
            return
        }
        guard let url = card.url else { return }
        if Herald.shared.deepLinkHandler?(url) == true { return }
        openURL(url)
    }

    private func dismiss(_ card: ContentCard) {
        hidden.insert(card.id)
        Herald.shared.logDismissal(card)
    }
}

extension ContentCardFeed where CardContent == ContentCardView {
    /// The feed with Herald's default card views.
    public init(
        filter: @escaping (ContentCard) -> Bool = { _ in true },
        order: @escaping (ContentCard, ContentCard) -> Bool = ContentCardFeedDefaults.order,
        emptyMessage: LocalizedStringKey = "No updates right now",
        onCardClick: ((ContentCard) -> Void)? = nil
    ) {
        self.init(filter: filter, order: order, emptyMessage: emptyMessage, onCardClick: onCardClick) { card, onClick in
            ContentCardView(card: card, onClick: onClick)
        }
    }
}

private struct CardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
#endif
