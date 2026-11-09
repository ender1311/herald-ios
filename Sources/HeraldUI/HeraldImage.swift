#if os(iOS)
import SwiftUI

/// A remote image at a fixed aspect ratio, decoded at the drawn size, with a flat placeholder (the
/// theme's outline color) while it loads or when it fails. Loads https and http URLs and files inside
/// the app bundle. Hidden from VoiceOver unless `accessibilityLabel` is set.
public struct HeraldImage: View {
    let url: URL?
    let aspectRatio: CGFloat
    let accessibilityLabel: String?
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

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
                GeometryReader { geometry in
                    // The long edge drawn, in pixels (aspect-fill crops the other one).
                    let edge = max(geometry.size.width, geometry.size.height) * displayScale
                    LoadedImage(url: url, maxPixelSize: Int(edge.rounded(.up)))
                        .frame(width: geometry.size.width, height: geometry.size.height)
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

private struct LoadedImage: View {
    let url: URL?
    let maxPixelSize: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: "\(url?.absoluteString ?? "")#\(maxPixelSize)") {
            guard let url, maxPixelSize > 0 else {
                image = nil
                return
            }
            image = HeraldImageLoader.shared.cached(url, maxPixelSize: maxPixelSize)
            if image == nil { image = await HeraldImageLoader.shared.load(url, maxPixelSize: maxPixelSize) }
        }
    }
}
#endif
