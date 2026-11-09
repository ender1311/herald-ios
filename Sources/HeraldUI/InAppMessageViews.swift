#if os(iOS)
import HeraldSDK
import SwiftUI

/// A banner at the top or bottom edge. A tap performs the first button's action (or dismisses when there
/// is none); swipe it toward its edge or sideways to dismiss.
public struct SlideupMessageView: View {
    let message: InAppMessage
    let actions: InAppMessageActions
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var drag: CGSize = .zero

    public init(message: InAppMessage, actions: InAppMessageActions) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        let colors = MessageColors(style: message.style, theme: theme, colorScheme: colorScheme)
        let first = message.content.buttons.first
        let fromTop = message.content.slideFrom == .top
        Button {
            if let first { actions.buttonClicked(first) } else { actions.dismiss() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                MessageText(message: message, colors: colors, alignment: .leading)
                if let first {
                    Text(first.text).font(theme.typography.button).foregroundStyle(colors.text)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(theme.spacing)
            .background(colors.background)
            .clipShape(RoundedRectangle(cornerRadius: colors.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(drag)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let dy = value.translation.height
                    drag = CGSize(width: value.translation.width, height: fromTop ? min(dy, 0) : max(dy, 0))
                }
                .onEnded { _ in
                    if abs(drag.height) > 40 || abs(drag.width) > 120 {
                        actions.dismiss()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { drag = .zero }
                    }
                }
        )
        .accessibilityAction(named: Text("Dismiss")) { actions.dismiss() }
        .padding(.horizontal, theme.spacing / 2)
        .padding(fromTop ? .top : .bottom, theme.spacing / 2)
    }
}

/// A centered dialog over a dimmed background, with optional image, header, body and buttons. Tapping
/// the dimmed area or the close button dismisses.
public struct ModalMessageView: View {
    let message: InAppMessage
    let actions: InAppMessageActions
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(message: InAppMessage, actions: InAppMessageActions) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        let colors = MessageColors(style: message.style, theme: theme, colorScheme: colorScheme)
        let content = VStack(spacing: 0) {
            if let url = message.content.imageUrl {
                HeraldImage(url: url, aspectRatio: 16 / 9)
            }
            VStack(spacing: theme.spacing) {
                MessageText(message: message, colors: colors, alignment: .center)
                MessageButtons(message: message, colors: colors, actions: actions)
            }
            .padding(theme.spacing * 1.5)
            .padding(.top, message.content.imageUrl == nil ? theme.spacing : 0)
        }
        ZStack {
            theme.colors(for: colorScheme).scrim
                .ignoresSafeArea()
                .onTapGesture { actions.dismiss() }
                .accessibilityHidden(true)
            ZStack(alignment: .topTrailing) {
                ViewThatFits(in: .vertical) {
                    content
                    ScrollView { content }
                }
                CloseButton(tint: colors.text, actions: actions)
            }
            .frame(maxWidth: 420)
            .background(colors.background)
            .clipShape(RoundedRectangle(cornerRadius: colors.cornerRadius, style: .continuous))
            .padding(theme.spacing * 1.5)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

/// Covers the screen: image on top, header, body, buttons, and a close button.
public struct FullScreenMessageView: View {
    let message: InAppMessage
    let actions: InAppMessageActions
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(message: InAppMessage, actions: InAppMessageActions) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        let colors = MessageColors(style: message.style, theme: theme, colorScheme: colorScheme)
        ZStack(alignment: .topTrailing) {
            colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let url = message.content.imageUrl {
                        HeraldImage(url: url, aspectRatio: 4 / 3)
                    }
                    VStack(alignment: .leading, spacing: theme.spacing) {
                        MessageText(message: message, colors: colors, alignment: .leading)
                        MessageButtons(message: message, colors: colors, actions: actions)
                    }
                    .padding(theme.spacing * 1.5)
                    .padding(.top, message.content.imageUrl == nil ? 44 : 0)
                }
            }
            CloseButton(tint: colors.text, actions: actions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Renders `content.html` in a web view: see `HTMLMessageWebView` for the `herald` bridge and link rules.
public struct HTMLMessageView: View {
    let message: InAppMessage
    let actions: InAppMessageActions
    @Environment(\.heraldTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    public init(message: InAppMessage, actions: InAppMessageActions) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        let colors = MessageColors(style: message.style, theme: theme, colorScheme: colorScheme)
        ZStack {
            colors.background.ignoresSafeArea()
            HTMLMessageWebView(html: message.content.html ?? "", background: colors.background, actions: actions)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Herald's default view for the message's type.
public struct DefaultInAppMessageView: View {
    let message: InAppMessage
    let actions: InAppMessageActions

    public init(message: InAppMessage, actions: InAppMessageActions) {
        self.message = message
        self.actions = actions
    }

    public var body: some View {
        switch message.type {
        case .slideup: SlideupMessageView(message: message, actions: actions)
        case .modal: ModalMessageView(message: message, actions: actions)
        case .full: FullScreenMessageView(message: message, actions: actions)
        case .html: HTMLMessageView(message: message, actions: actions)
        }
    }
}

struct MessageText: View {
    let message: InAppMessage
    let colors: MessageColors
    let alignment: HorizontalAlignment
    @Environment(\.heraldTheme) private var theme

    var body: some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        VStack(alignment: alignment, spacing: 6) {
            if let header = message.content.header {
                Text(header).font(theme.typography.title).accessibilityAddTraits(.isHeader)
            }
            if let body = message.content.body {
                Text(body).font(theme.typography.body)
            }
        }
        .foregroundStyle(colors.text)
        .multilineTextAlignment(textAlignment)
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MessageButtons: View {
    let message: InAppMessage
    let colors: MessageColors
    let actions: InAppMessageActions
    @Environment(\.heraldTheme) private var theme

    var body: some View {
        if !message.content.buttons.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(message.content.buttons.enumerated()), id: \.element.id) { index, button in
                    let primary = index == 0
                    Button { actions.buttonClicked(button) } label: {
                        Text(button.text)
                            .font(theme.typography.button)
                            .foregroundStyle(primary ? colors.buttonText : colors.text)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, theme.spacing)
                            .background(primary ? colors.button : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: colors.cornerRadius, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CloseButton: View {
    let tint: Color
    let actions: InAppMessageActions

    var body: some View {
        Button { actions.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
    }
}
#endif
