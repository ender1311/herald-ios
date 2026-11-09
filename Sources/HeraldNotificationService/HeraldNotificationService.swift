import Foundation
import UserNotifications

/// Rich push for a Notification Service Extension: adds the action buttons and attaches the image a
/// Herald push carries.
///
/// Herald's APNs payload (`src/lib/esp/providers/apns.ts`) sets `aps.mutable-content: 1` and an
/// `image_url` key when the push has an image (`image` is read too, as on Android). Optional
/// `herald_actions` (up to 3 buttons, `[{"id","title","deeplink"?}]`, the same key the Android SDK
/// reads) become a notification category registered on the fly, unless the payload already names one
/// in `aps.category`. This module depends on Foundation and UserNotifications only, so it links into an
/// app extension (HeraldSDK does not: it uses `UIApplication`).
///
/// Subclass it as the extension's principal class:
/// ```swift
/// import HeraldNotificationService
/// final class NotificationService: HeraldNotificationService {}
/// ```
/// or call `HeraldRichPush.prepare(_:timeout:)` from your own `UNNotificationServiceExtension`.
open class HeraldNotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// How long to wait for the image before showing the push without it.
    open var imageTimeout: TimeInterval { HeraldRichPush.defaultTimeout }

    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// The best content so far: the original, then with its action buttons. Delivered on expiry.
    private var best: UNNotificationContent?
    private let lock = NSLock()

    override open func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            best = request.content
        }
        // UNNotificationContent is immutable but not marked Sendable.
        nonisolated(unsafe) let content = request.content
        let timeout = imageTimeout
        Task {
            nonisolated(unsafe) let withActions = await HeraldRichPush.applyActions(to: content)
            self.lock.withLock { self.best = withActions }
            let result = await HeraldRichPush.attachImage(to: withActions, timeout: timeout)
            self.deliver(result)
        }
    }

    override open func serviceExtensionTimeWillExpire() {
        lock.withLock { best }.map(deliver)
    }

    /// Calls the content handler once; later calls do nothing.
    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}

public enum HeraldRichPush {
    /// Payload keys for the image URL, in the order they are read. Herald's APNs sender uses `image_url`.
    public static let imageKeys = ["image_url", "image"]
    /// Under the system's roughly 30 s limit for a service extension.
    public static let defaultTimeout: TimeInterval = 20
    /// Larger downloads are skipped (the system limit for an image attachment is 10 MB).
    static let maxBytes = 10 * 1024 * 1024

    /// The payload key with up to 3 action buttons.
    public static let actionsKey = "herald_actions"
    public static let maxActions = 3
    static let categoryPrefix = "herald.actions."
    /// How many `herald.actions.*` categories to keep registered (newest first).
    static let maxActionCategories = 10

    /// Adds the push's action buttons, then its image. Returns `content` unchanged when it has neither.
    public static func prepare(
        _ content: UNNotificationContent, timeout: TimeInterval = defaultTimeout, session: URLSession = .shared
    ) async -> UNNotificationContent {
        await attachImage(to: await applyActions(to: content), timeout: timeout, session: session)
    }

    /// Registers a category for the push's `herald_actions` and sets it on the content. Unchanged when
    /// there are no actions or `aps.category` is already set.
    public static func applyActions(to content: UNNotificationContent) async -> UNNotificationContent {
        guard content.categoryIdentifier.isEmpty else { return content }
        let buttons = actions(content.userInfo[actionsKey])
        guard !buttons.isEmpty, let mutable = content.mutableCopy() as? UNMutableNotificationContent else { return content }
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        let (category, updated) = register(buttons, existing: existing, now: Date())
        if let updated {
            center.setNotificationCategories(updated)
            // Read back so the registration has landed before the notification is shown.
            _ = await center.notificationCategories()
        }
        mutable.categoryIdentifier = category
        return mutable
    }

    /// The category id for `buttons` and the new category set (nil when an identical category is
    /// already registered). Ids are `herald.actions.<hash of buttons>.<unix seconds>`; only the newest
    /// `maxActionCategories` Herald categories are kept, and the app's own categories are untouched.
    static func register(
        _ buttons: [(id: String, title: String)], existing: Set<UNNotificationCategory>, now: Date
    ) -> (id: String, categories: Set<UNNotificationCategory>?) {
        let key = buttons.map { "\($0.id)\u{1F}\($0.title)" }.joined(separator: "\u{1E}")
        let prefix = "\(categoryPrefix)\(fnv1a(key))."
        if let match = existing.first(where: { $0.identifier.hasPrefix(prefix) }) {
            return (match.identifier, nil)
        }
        let id = "\(prefix)\(Int(now.timeIntervalSince1970))"
        let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) }
        let category = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
        let herald = existing.filter { $0.identifier.hasPrefix(categoryPrefix) }
            .sorted { timestamp($0.identifier) > timestamp($1.identifier) }
        let keep = herald.prefix(maxActionCategories - 1)
        let others = existing.filter { !$0.identifier.hasPrefix(categoryPrefix) }
        return (id, others.union(keep).union([category]))
    }

    private static func timestamp(_ identifier: String) -> Int {
        Int(identifier.split(separator: ".").last ?? "") ?? 0
    }

    /// `herald_actions` as a JSON array or a JSON string; malformed entries skipped, at most 3 kept.
    static func actions(_ value: Any?) -> [(id: String, title: String)] {
        var raw = value
        if let text = value as? String, let data = text.data(using: .utf8) {
            raw = try? JSONSerialization.jsonObject(with: data)
        }
        guard let items = raw as? [Any] else { return [] }
        let parsed = items.compactMap { item -> (id: String, title: String)? in
            guard let object = item as? [String: Any], let id = object["id"] as? String, !id.isEmpty,
                let title = object["title"] as? String, !title.isEmpty
            else { return nil }
            return (id, title)
        }
        return Array(parsed.prefix(maxActions))
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Returns `content` with the push's image attached, or `content` unchanged when there is no https
    /// image, the download fails or times out, it is over 10 MB, or it is not JPEG, PNG, GIF or HEIC.
    public static func attachImage(
        to content: UNNotificationContent, timeout: TimeInterval = defaultTimeout, session: URLSession = .shared
    ) async -> UNNotificationContent {
        guard let url = imageURL(in: content.userInfo),
            let attachment = await downloadAttachment(from: url, timeout: timeout, session: session),
            let mutable = content.mutableCopy() as? UNMutableNotificationContent
        else { return content }
        mutable.attachments = [attachment]
        return mutable
    }

    /// The first `imageKeys` value that is an https URL.
    public static func imageURL(in userInfo: [AnyHashable: Any]) -> URL? {
        for key in imageKeys {
            if let text = userInfo[key] as? String, let url = URL(string: text), url.scheme?.lowercased() == "https" {
                return url
            }
        }
        return nil
    }

    /// Downloads to a file (never into memory, so a large body cannot exhaust the extension's memory).
    static func downloadAttachment(from url: URL, timeout: TimeInterval, session: URLSession) async -> UNNotificationAttachment? {
        var mutableRequest = URLRequest(url: url)
        mutableRequest.timeoutInterval = timeout
        let request = mutableRequest
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var downloaded: URL?
        defer { if let downloaded { try? fileManager.removeItem(at: downloaded) } }
        do {
            let (file, response) = try await withTimeout(timeout) { try await session.download(for: request) }
            downloaded = file
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                size > 0, size <= maxBytes, http.expectedContentLength <= Int64(maxBytes),
                let ext = fileExtension(mimeType: http.mimeType, url: url)
            else { return nil }
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("image.\(ext)")
            try fileManager.moveItem(at: file, to: target)
            downloaded = nil
            // The system moves the file into its own store on success.
            return try UNNotificationAttachment(identifier: "herald-image", url: target)
        } catch {
            try? fileManager.removeItem(at: dir)
            return nil
        }
    }

    /// The system picks the attachment type from the file extension. Only types UNNotificationAttachment
    /// accepts for images.
    static func fileExtension(mimeType: String?, url: URL) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        default:
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "heic"].contains(ext) ? ext : nil
        }
    }

    private struct Timeout: Error {}

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw Timeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout() }
            return first
        }
    }
}
