#if os(iOS)
import HeraldSDK
import os
import SwiftUI

enum HeraldUILog {
    static let logger = Logger(subsystem: "com.herald.sdk", category: "ui")
}

/// The current user's content cards from `Herald.shared.contentCards`, pinned first then newest.
///
/// Impressions are logged once per card per session (across feeds and relaunches) when at least half
/// of it is visible. Clicks are logged, then
/// passed to `onCardClick`, or by default the card's url opens through `Herald.shared.deepLinkHandler`
/// and then the environment's `openURL`. Dismissible cards can be swiped away (VoiceOver: the Dismiss
/// action), which logs the dismissal. Impressions are written to the unified log
/// (subsystem `com.herald.sdk`, category `ui`, debug level).
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
            if cards.isEmpty {
                Text(emptyMessage)
                    .font(theme.typography.body)
                    .foregroundStyle(colors.onSurfaceVariant)
                    .padding(theme.spacing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.spacing * 0.75) {
                        ForEach(cards) { card in
                            FeedRow(
                                card: card, viewportHeight: viewport.size.height, space: Self.space,
                                onVisible: { logImpression(card) }, onDismiss: { dismiss(card) }
                            ) {
                                cardContent(card) { click(card) }
                            }
                        }
                    }
                    .padding(theme.spacing)
                }
                .coordinateSpace(name: Self.space)
            }
        }
        .background(colors.background)
    }

    private func logImpression(_ card: ContentCard) {
        guard !impressed.contains(card.id) else { return }
        impressed.insert(card.id)
        HeraldUILog.logger.debug("Card impression \(card.id, privacy: .public)")
        Herald.shared.logImpression(card)
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

/// One card: reports when at least half of it is inside the scroll view, and handles swipe-to-dismiss
/// (a horizontal drag past a third of its width; VoiceOver: the Dismiss action) when the card allows it.
private struct FeedRow<Content: View>: View {
    let card: ContentCard
    let viewportHeight: CGFloat
    let space: String
    let onVisible: () -> Void
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var dragX: CGFloat = 0
    @State private var width: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let row = content()
            .background(GeometryReader { geometry in
                let frame = geometry.frame(in: .named(space))
                Color.clear
                    .onAppear { measure(frame) }
                    .onChange(of: frame) { measure($0) }
            })
            .offset(x: dragX)
        if card.dismissible {
            row
                .simultaneousGesture(swipe)
                .accessibilityAction(named: Text("Dismiss")) { onDismiss() }
        } else {
            row
        }
    }

    private func measure(_ frame: CGRect) {
        width = frame.width
        let visible = frame.intersection(CGRect(x: frame.minX, y: 0, width: frame.width, height: viewportHeight))
        if ContentCardFeedDefaults.isImpression(visibleHeight: visible.isNull ? 0 : visible.height, fullHeight: frame.height) {
            onVisible()
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                // Vertical drags belong to the scroll view.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { _ in
                if width > 0, abs(dragX) > width / 3 {
                    let target = dragX > 0 ? width * 1.5 : -width * 1.5
                    if reduceMotion { onDismiss() } else {
                        withAnimation(.easeOut(duration: 0.2)) { dragX = target }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { onDismiss() }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
                }
            }
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
#endif
