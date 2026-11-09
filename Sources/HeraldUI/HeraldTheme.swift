import HeraldSDK
import SwiftUI

/// Colors used by the default card and in-app views.
public struct HeraldColors: Sendable, Hashable {
    /// Feed and full-screen message background.
    public var background: Color
    /// Card, slideup and modal surface.
    public var surface: Color
    /// Primary text on `surface` and `background`.
    public var onSurface: Color
    /// Secondary text (card body, captions).
    public var onSurfaceVariant: Color
    /// Button and call-to-action color.
    public var accent: Color
    /// Text on `accent`.
    public var onAccent: Color
    /// Hairline borders and image placeholders.
    public var outline: Color
    /// Dim layer behind modal messages.
    public var scrim: Color

    public init(
        background: Color, surface: Color, onSurface: Color, onSurfaceVariant: Color, accent: Color,
        onAccent: Color, outline: Color, scrim: Color
    ) {
        self.background = background
        self.surface = surface
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
        self.accent = accent
        self.onAccent = onAccent
        self.outline = outline
        self.scrim = scrim
    }

    public static let light = HeraldColors(
        background: Color(heraldHex: "#F7F7F8")!, surface: .white, onSurface: Color(heraldHex: "#101828")!,
        onSurfaceVariant: Color(heraldHex: "#475467")!, accent: Color(heraldHex: "#2E5BFF")!, onAccent: .white,
        outline: Color(heraldHex: "#E4E7EC")!, scrim: Color.black.opacity(0.6)
    )

    public static let dark = HeraldColors(
        background: Color(heraldHex: "#0C111D")!, surface: Color(heraldHex: "#161B26")!,
        onSurface: Color(heraldHex: "#F5F5F6")!, onSurfaceVariant: Color(heraldHex: "#94969C")!,
        accent: Color(heraldHex: "#6E8BFF")!, onAccent: Color(heraldHex: "#0C111D")!,
        outline: Color(heraldHex: "#333741")!, scrim: Color.black.opacity(0.7)
    )
}

/// Fonts used by the default views. The defaults are text styles, so Dynamic Type applies; for a custom
/// font use `Font.custom(_:size:relativeTo:)` to keep it.
public struct HeraldTypography: @unchecked Sendable {
    public var title: Font
    public var body: Font
    public var button: Font
    public var caption: Font

    public init(
        title: Font = .headline, body: Font = .subheadline, button: Font = .subheadline.weight(.semibold),
        caption: Font = .footnote
    ) {
        self.title = title
        self.body = body
        self.button = button
        self.caption = caption
    }
}

/// The look of Herald's default views. Set it on a view tree with `.heraldTheme(_:)` (content card feed)
/// and pass it to `HeraldInAppPresenter` / `Herald.useDefaultInAppUI(theme:)`. Style fields set on an
/// in-app message override the matching theme values for that message.
public struct HeraldTheme: Sendable {
    public var lightColors: HeraldColors
    public var darkColors: HeraldColors
    public var typography: HeraldTypography
    public var cornerRadius: CGFloat
    /// Base spacing unit: outer padding of cards and messages.
    public var spacing: CGFloat
    /// true or false forces dark or light colors; nil follows the system setting.
    public var darkMode: Bool?

    public init(
        lightColors: HeraldColors = .light, darkColors: HeraldColors = .dark, typography: HeraldTypography = HeraldTypography(),
        cornerRadius: CGFloat = 12, spacing: CGFloat = 16, darkMode: Bool? = nil
    ) {
        self.lightColors = lightColors
        self.darkColors = darkColors
        self.typography = typography
        self.cornerRadius = cornerRadius
        self.spacing = spacing
        self.darkMode = darkMode
    }

    /// The colors for the current light or dark setting.
    public func colors(for colorScheme: ColorScheme) -> HeraldColors {
        (darkMode ?? (colorScheme == .dark)) ? darkColors : lightColors
    }
}

private struct HeraldThemeKey: EnvironmentKey {
    static let defaultValue = HeraldTheme()
}

extension EnvironmentValues {
    /// The theme Herald's default views read.
    public var heraldTheme: HeraldTheme {
        get { self[HeraldThemeKey.self] }
        set { self[HeraldThemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the theme for Herald views inside this view.
    public func heraldTheme(_ theme: HeraldTheme) -> some View {
        environment(\.heraldTheme, theme)
    }
}

extension Color {
    /// Parses "#RRGGBB" or "#AARRGGBB" (the format Herald message styles use); nil when invalid.
    public init?(heraldHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let alpha = text.count == 8 ? Double((value >> 24) & 0xFF) / 255 : 1
        self.init(
            .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255, opacity: alpha
        )
    }
}

/// Message colors after applying the message's style overrides on top of the theme.
public struct MessageColors: Sendable, Hashable {
    public var background: Color
    public var text: Color
    public var button: Color
    public var buttonText: Color
    public var cornerRadius: CGFloat

    /// Each nil or invalid style field falls back to the theme.
    public init(style: InAppMessage.Style, theme: HeraldTheme, colorScheme: ColorScheme) {
        let colors = theme.colors(for: colorScheme)
        background = Color(heraldHex: style.backgroundColor) ?? colors.surface
        text = Color(heraldHex: style.textColor) ?? colors.onSurface
        button = Color(heraldHex: style.buttonColor) ?? colors.accent
        buttonText = Color(heraldHex: style.buttonTextColor) ?? colors.onAccent
        cornerRadius = style.cornerRadius.map { CGFloat($0) } ?? theme.cornerRadius
    }
}
