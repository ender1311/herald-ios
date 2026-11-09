#if os(iOS)
import SwiftUI

/// A remote image at a fixed aspect ratio, with a flat placeholder (the theme's outline color) while it
/// loads or when it fails. Hidden from VoiceOver unless `accessibilityLabel` is set.
public struct HeraldImage: View {
    let url: URL?
    let aspectRatio: CGFloat
    let accessibilityLabel: String?
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(url: URL?, aspectRatio: CGFloat, accessibilityLabel: String? = nil) {
        self.url = url
        self.aspectRatio = aspectRatio
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let image = Rectangle()
            .fill(theme.colors(for: colorScheme).outline)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
            .clipped()
        if let accessibilityLabel {
            image.accessibilityElement().accessibilityLabel(accessibilityLabel).accessibilityAddTraits(.isImage)
        } else {
            image.accessibilityHidden(true)
        }
    }
}
#endif
