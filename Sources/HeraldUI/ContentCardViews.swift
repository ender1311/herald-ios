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

/// Image on top, then title, body and call to action. A card with a video shows it in place of the
/// image (see `VideoCardFrame`).
public struct CaptionedImageContentCardView: View {
    let card: ContentCard
    let onClick: () -> Void

    public init(card: ContentCard, onClick: @escaping () -> Void) {
        self.card = card
        self.onClick = onClick
    }

    public var body: some View {
        if let video = card.videoUrl {
            VideoCardFrame(card: card, video: video, onClick: onClick)
        } else {
            CardFrame(card: card, onClick: onClick) {
                VStack(alignment: .leading, spacing: 0) {
                    HeraldImage(url: card.imageUrl, aspectRatio: 16 / 9)
                    CardText(card: card)
                }
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

/// `CardFrame` for a captioned card with a video: the player sits outside the card's button, so its play
/// button and controls get their own taps and VoiceOver focus; the text below is the card's button.
struct VideoCardFrame: View {
    let card: ContentCard
    let video: URL
    let onClick: () -> Void
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = theme.colors(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        let text = CardText(card: card).frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 0) {
            HeraldVideoView(
                url: video, posterUrl: card.videoPosterUrl ?? card.imageUrl, aspectRatio: 16 / 9, autoplay: card.videoAutoplay,
                onPlay: { Herald.shared.logVideoPlay(card) }, onComplete: { Herald.shared.logVideoComplete(card) }
            )
            if card.url != nil {
                Button(action: onClick) { text.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                text.accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(colors.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.outline, lineWidth: 1))
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
