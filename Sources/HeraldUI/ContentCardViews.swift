#if os(iOS)
import HeraldSDK
import SwiftUI

/// Herald's default card for `card`, chosen by its type. Use it in a custom `cardContent` for the types
/// you do not replace.
public struct ContentCardView: View {
    let card: ContentCard
    let onClick: () -> Void

    public init(card: ContentCard, onClick: @escaping () -> Void) {
        self.card = card
        self.onClick = onClick
    }

    public var body: some View {
        switch card.type {
        case .classic: ClassicContentCardView(card: card, onClick: onClick)
        case .captionedImage: CaptionedImageContentCardView(card: card, onClick: onClick)
        case .imageOnly: ImageOnlyContentCardView(card: card, onClick: onClick)
        }
    }
}

/// Title, body and call to action.
public struct ClassicContentCardView: View {
    let card: ContentCard
    let onClick: () -> Void

    public init(card: ContentCard, onClick: @escaping () -> Void) {
        self.card = card
        self.onClick = onClick
    }

    public var body: some View {
        CardFrame(card: card, onClick: onClick) { CardText(card: card) }
    }
}

/// Image on top, then title, body and call to action.
public struct CaptionedImageContentCardView: View {
    let card: ContentCard
    let onClick: () -> Void

    public init(card: ContentCard, onClick: @escaping () -> Void) {
        self.card = card
        self.onClick = onClick
    }

    public var body: some View {
        CardFrame(card: card, onClick: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                HeraldImage(url: card.imageUrl, aspectRatio: 16 / 9)
                CardText(card: card)
            }
        }
    }
}

/// Image only. VoiceOver reads the card title, or `extras["alt"]` when the card has no title.
public struct ImageOnlyContentCardView: View {
    let card: ContentCard
    let onClick: () -> Void

    public init(card: ContentCard, onClick: @escaping () -> Void) {
        self.card = card
        self.onClick = onClick
    }

    public var body: some View {
        CardFrame(card: card, onClick: onClick) {
            HeraldImage(url: card.imageUrl, aspectRatio: 2, accessibilityLabel: ContentCardFeedDefaults.imageDescription(card))
        }
    }
}

/// Shared frame of the default cards: surface, corner radius, border, 44 pt minimum height, and a
/// button when the card has a url.
struct CardFrame<Content: View>: View {
    let card: ContentCard
    let onClick: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        let framed = content()
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(colors.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(colors.outline, lineWidth: 1))
            .contentShape(shape)
        if card.url != nil {
            Button(action: onClick) { framed }.buttonStyle(.plain)
        } else {
            framed.accessibilityElement(children: .combine)
        }
    }
}

struct CardText: View {
    let card: ContentCard
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        VStack(alignment: .leading, spacing: 4) {
            if let title = card.title {
                Text(title).font(theme.typography.title).foregroundStyle(colors.onSurface)
            }
            if let body = card.body {
                Text(body).font(theme.typography.body).foregroundStyle(colors.onSurfaceVariant)
            }
            if let cta = card.cta {
                Text(cta).font(theme.typography.button).foregroundStyle(colors.accent).padding(.top, theme.spacing / 4)
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(theme.spacing)
    }
}
#endif
