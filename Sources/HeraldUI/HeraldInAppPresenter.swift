#if os(iOS)
import HeraldSDK
import SwiftUI
import UIKit

/// Herald's default in-app message presenter.
///
/// It draws each message in its own overlay window on the active foreground window scene, above the
/// app's windows. Slideups let touches outside the banner reach the app; modal, full-screen and HTML
/// messages cover it and keep VoiceOver inside the message (the escape gesture closes it). The window
/// is removed when the message closes. With Reduce Motion on, messages fade instead of sliding.
///
/// Install it once after `Herald.configure`: `Herald.useDefaultInAppUI(theme: theme)`.
@MainActor
public final class HeraldInAppPresenter: InAppMessagePresenter {
    /// Draws one message. Return nil to use Herald's default view for that message.
    public typealias ViewProvider = @MainActor (InAppMessage, InAppMessageActions) -> AnyView?

    /// Colors, fonts, radius and spacing; style fields on a message override it.
    public var theme: HeraldTheme
    /// Replaces the default view per message type: return your view, or nil for the default.
    public var viewProvider: ViewProvider?

    private var current: OverlaySession?

    public init(theme: HeraldTheme = HeraldTheme(), viewProvider: ViewProvider? = nil) {
        self.theme = theme
        self.viewProvider = viewProvider
    }

    /// True once the message's window is on screen. False while another message is up or when no
    /// window scene is in the foreground; Herald then keeps the message pending.
    public func present(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard current == nil, let scene = Self.activeScene() else { return false }
        current = OverlaySession(
            scene: scene, message: message, theme: theme, viewProvider: viewProvider,
            onRemoved: { [weak self] in
                self?.current = nil
                onClose()
            }
        )
        return true
    }

    static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

extension Herald {
    /// Creates Herald's default presenter and sets it as `Herald.shared.inAppMessagePresenter`.
    @MainActor @discardableResult
    public static func useDefaultInAppUI(
        theme: HeraldTheme = HeraldTheme(), viewProvider: HeraldInAppPresenter.ViewProvider? = nil
    ) -> HeraldInAppPresenter {
        let presenter = HeraldInAppPresenter(theme: theme, viewProvider: viewProvider)
        Herald.shared.inAppMessagePresenter = presenter
        return presenter
    }
}

/// One message on screen: its window, hosting controller and close flow.
@MainActor
final class OverlaySession {
    private let window: OverlayWindow
    private let model = OverlayModel()
    private weak var previousKeyWindow: UIWindow?
    private var disconnectObserver: NSObjectProtocol?
    private var onRemoved: (() -> Void)?

    init(
        scene: UIWindowScene, message: InAppMessage, theme: HeraldTheme, viewProvider: HeraldInAppPresenter.ViewProvider?,
        onRemoved: @escaping () -> Void
    ) {
        self.onRemoved = onRemoved
        let blocking = message.type != .slideup
        window = OverlayWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        if let dark = theme.darkMode { window.overrideUserInterfaceStyle = dark ? .dark : .light }
        window.passthrough = !blocking
        window.hitRegion = model

        var finish: () -> Void = {}
        let actions = InAppMessageActions(message: message) { finish() }
        let content = viewProvider?(message, actions) ?? AnyView(DefaultInAppMessageView(message: message, actions: actions))
        let host = UIHostingController(rootView: OverlayHost(model: model, message: message, actions: actions, theme: theme, content: content))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = blocking
        window.rootViewController = host

        if blocking {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window.makeKeyAndVisible()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        } else {
            window.isHidden = false
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }

        finish = { [weak self] in self?.close() }
        // A scene torn down with the message up: remove it without logging, so the next one can show.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: scene, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove() }
        }
    }

    private func close() {
        model.hide()
        // Let the exit transition play, then take the window down.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.remove()
        }
    }

    /// Safe to call more than once; reports the close exactly once.
    private func remove() {
        guard let onRemoved else { return }
        self.onRemoved = nil
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        // Hiding resigns key, so check first.
        let wasKey = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        if wasKey { previousKeyWindow?.makeKey() }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        onRemoved()
    }
}

/// Drives the enter and exit transitions and records the slideup banner's frame for hit testing.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var visible = false
    var bannerFrame: CGRect = .zero

    func hide() {
        withAnimation(.easeIn(duration: 0.25)) { visible = false }
    }
}

/// Passes touches outside the slideup banner through to the app's windows.
final class OverlayWindow: UIWindow {
    var passthrough = false
    weak var hitRegion: OverlayModel?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if passthrough, let region = hitRegion, !region.bannerFrame.contains(point) {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

struct OverlayHost: View {
    @ObservedObject var model: OverlayModel
    let message: InAppMessage
    let actions: InAppMessageActions
    let theme: HeraldTheme
    let content: AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fromTop: Bool { message.content.slideFrom == .top }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        switch message.type {
        case .slideup: return .move(edge: fromTop ? .top : .bottom).combined(with: .opacity)
        case .modal: return .opacity.combined(with: .scale(scale: 0.92))
        case .full, .html: return .opacity
        }
    }

    var body: some View {
        ZStack(alignment: message.type == .slideup ? (fromTop ? .top : .bottom) : .center) {
            Color.clear
            if model.visible {
                content
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { model.bannerFrame = geometry.frame(in: .global) }
                            .onChange(of: geometry.frame(in: .global)) { model.bannerFrame = $0 }
                    })
                    .transition(transition)
                    .accessibilityAction(.escape) { actions.dismiss() }
            }
        }
        .heraldTheme(theme)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85)) {
                model.visible = true
            }
        }
        .task { await autoDismiss() }
    }

    /// Slideups with `dismissAfterSeconds` go away on their own, except while VoiceOver is running.
    private func autoDismiss() async {
        guard message.type == .slideup, let seconds = message.content.dismissAfterSeconds, seconds > 0,
            !UIAccessibility.isVoiceOverRunning
        else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if !Task.isCancelled { actions.dismiss() }
    }
}
#endif
