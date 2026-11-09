#if DEBUG
import HeraldSDK
import SwiftUI

/// Debug only: loads the shared `messages.json` fixture through Herald's debug hooks, so every card and
/// in-app type renders without a server.
struct PreviewMessagesView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Load fixture cards and messages") { PreviewMessages.load() }
                } footer: {
                    Text("Cards appear on the Home tab.")
                }
                Section("In-app messages") {
                    ForEach(PreviewMessages.kinds, id: \.self) { kind in
                        Button(kind.capitalized) { Task { await PreviewMessages.show(kind) } }
                    }
                }
            }
            .navigationTitle("Preview messages")
        }
    }
}

enum PreviewLaunch {
    /// The value after `-HeraldPreview` in the launch arguments.
    static var target: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HeraldPreview"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

enum PreviewMessages {
    static let kinds = ["slideup", "modal", "full", "html"]
    /// Fixture message per type. The fixture has no full-screen message, so `load()` adds a copy of the modal.
    private static let ids = ["slideup": "msg_5", "modal": "msg_2", "full": "preview_full", "html": "msg_6"]

    static func load() {
        guard let url = Bundle.main.url(forResource: "messages", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var body = root["data"] as? [String: Any],
            var messages = body["inAppMessages"] as? [[String: Any]],
            var full = messages.first(where: { $0["id"] as? String == "msg_2" })
        else { return }
        // The fixture's example.com images do not exist; show a bundled photo instead.
        let image: Any = Bundle.main.url(forResource: "preview-image", withExtension: "webp")?.absoluteString ?? NSNull()
        if var cards = body["contentCards"] as? [[String: Any]] {
            for index in cards.indices where cards[index]["imageUrl"] is String { cards[index]["imageUrl"] = image }
            body["contentCards"] = cards
        }
        for index in messages.indices where messages[index]["id"] as? String == "msg_2" {
            var content = messages[index]["content"] as? [String: Any] ?? [:]
            content["imageUrl"] = image
            messages[index]["content"] = content
            full["content"] = content
        }
        full["id"] = "preview_full"
        full["type"] = "full"
        messages.append(full)
        body["inAppMessages"] = messages
        root["data"] = body
        guard let json = try? JSONSerialization.data(withJSONObject: root) else { return }
        Herald.shared.debugLoadMessages(json)
    }

    @MainActor
    static func show(_ kind: String) async {
        guard let id = ids[kind] else { return }
        load()
        // Give the load a moment to apply and the scene to become active.
        try? await Task.sleep(nanoseconds: 700_000_000)
        Herald.shared.debugShowInAppMessage(id)
    }
}
#endif
