#if os(iOS)
import SwiftUI
import WebKit

/// The web view behind `HTMLMessageView`. JavaScript is on for this view only, with a `herald` object:
/// `herald.close()` dismisses and `herald.click(id)` logs a button click. The page is loaded with no
/// base URL, so it cannot read files; it gets a non-persistent data store. Any link the page opens is
/// logged as a click and handed to `Herald.shared.openDeepLink` (the app or the system opens it,
/// outside the message), and the message closes.
struct HTMLMessageWebView: UIViewRepresentable {
    let html: String
    let background: Color
    let actions: InAppMessageActions

    static let bridgeScript = """
        window.herald = Object.freeze({
          close: function () { window.webkit.messageHandlers.herald.postMessage({ action: "close" }); },
          click: function (id) { window.webkit.messageHandlers.herald.postMessage({ action: "click", id: String(id) }); }
        });
        """

    /// Pages without a viewport tag would render at desktop width; give them the device width.
    static let viewportScript = """
        if (!document.querySelector('meta[name="viewport"]')) {
          var meta = document.createElement("meta");
          meta.name = "viewport";
          meta.content = "width=device-width, initial-scale=1";
          document.head.appendChild(meta);
        }
        """

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(context.coordinator), name: "herald")
        controller.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.viewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(background)
        webView.scrollView.backgroundColor = UIColor(background)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "herald")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let actions: InAppMessageActions

        init(actions: InAppMessageActions) {
            self.actions = actions
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            switch body["action"] as? String {
            case "close":
                actions.dismiss()
            case "click":
                if let id = body["id"] as? String { actions.clicked(buttonId: id) }
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            // The initial loadHTMLString document.
            if url.absoluteString == "about:blank", navigationAction.navigationType == .other {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            if Self.opensOutside(url), navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame != false {
                actions.bodyClicked(url: url)
            }
        }

        /// target="_blank" and window.open: same as a link.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, Self.opensOutside(url) {
                actions.bodyClicked(url: url)
            }
            return nil
        }

        /// Never hand file, javascript, data or about URLs to the app.
        static func opensOutside(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return !["file", "javascript", "data", "about", "blob"].contains(scheme)
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the coordinator.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
#endif
