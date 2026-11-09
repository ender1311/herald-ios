#if os(iOS)
import Foundation
import HeraldSDK

/// What a message view can do. Default and custom views report every user action through it, so
/// Herald logs the interaction and frees the screen for the next message.
@MainActor
public final class InAppMessageActions {
    public let message: InAppMessage
    private let onFinish: () -> Void
    private var clickedOnce = false
    private var finished = false

    init(message: InAppMessage, onFinish: @escaping () -> Void) {
        self.message = message
        self.onFinish = onFinish
    }

    /// Logs a button click, performs its action (opens the deep link or URL), then takes the message down.
    public func buttonClicked(_ button: InAppMessage.Button) {
        guard !finished else { return }
        Herald.shared.logClick(message, buttonId: button.id)
        clickedOnce = true
        // Deep links and web URLs both go through the app's deepLinkHandler, then the system.
        if let url = button.action.url {
            Herald.shared.openDeepLink(url)
        }
        finish()
    }

    /// Logs a click on the message body (no button), opens `url` when given, then takes the message down.
    public func bodyClicked(url: URL? = nil) {
        guard !finished else { return }
        Herald.shared.logClick(message, buttonId: nil)
        clickedOnce = true
        if let url { Herald.shared.openDeepLink(url) }
        finish()
    }

    /// Logs a click with a button id and keeps the message up (the HTML bridge's `herald.click(id)`).
    public func clicked(buttonId: String) {
        guard !finished, !buttonId.isEmpty else { return }
        Herald.shared.logClick(message, buttonId: buttonId)
        clickedOnce = true
    }

    /// Takes the message down. A dismissal is logged only when nothing was clicked.
    public func dismiss() {
        guard !finished else { return }
        if !clickedOnce { Herald.shared.logDismissal(message) }
        finish()
    }

    private func finish() {
        finished = true
        onFinish()
    }
}
#endif
