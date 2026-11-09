import Foundation
import UserNotifications

/// Rich push for a Notification Service Extension: attaches the image a Herald push carries and adds
/// its action buttons.
///
/// Herald's APNs payload (`src/lib/esp/providers/apns.ts`) sets `aps.mutable-content: 1` and an
/// `image_url` key when the push has an image. Optional `herald_actions` (up to 3 buttons,
/// `[{"id","title","deeplink"?}]`, the same key the Android SDK reads) become a notification category
/// registered on the fly, unless the payload already names one in `aps.category`. This module depends on Foundation and UserNotifications
/// only, so it links into an app extension (HeraldSDK does not: it uses `UIApplication`).
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
    private var original: UNNotificationContent?
    private let lock = NSLock()

    override open func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            original = request.content
        }
        // UNNotificationContent is immutable but not marked Sendable.
        nonisolated(unsafe) let content = request.content
        let timeout = imageTimeout
        Task {
            let result = await HeraldRichPush.prepare(content, timeout: timeout)
            self.deliver(result)
        }
    }

    override open func serviceExtensionTimeWillExpire() {
        lock.withLock { original }.map(deliver)
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
    /// The payload key Herald's APNs sender puts the image URL in.
    public static let imageKey = "image_url"
    /// Under the system's roughly 30 s limit for a service extension.
    public static let defaultTimeout: TimeInterval = 20
    /// Larger downloads are skipped (the system limit for an image attachment is 10 MB).
    static let maxBytes = 10 * 1024 * 1024

    /// The payload key with up to 3 action buttons.
    public static let actionsKey = "herald_actions"
    public static let maxActions = 3

    /// Adds the push's action buttons, then its image. Returns `content` unchanged when it has neither.
    public static func prepare(
        _ content: UNNotificationContent, timeout: TimeInterval = defaultTimeout, session: URLSession = .shared
    ) async -> UNNotificationContent {
        var result = content
        if let category = actionCategory(for: content), let mutable = content.mutableCopy() as? UNMutableNotificationContent {
            let center = UNUserNotificationCenter.current()
            let existing = await center.notificationCategories()
            if !existing.contains(where: { $0.identifier == category.identifier }) {
                center.setNotificationCategories(existing.union([category]))
                // Read back so the registration has landed before the notification is shown.
                _ = await center.notificationCategories()
            }
            mutable.categoryIdentifier = category.identifier
            result = mutable
        }
        return await attachImage(to: result, timeout: timeout, session: session)
    }

    /// A category for the payload's `herald_actions`; nil when there are none or `aps.category` is set.
    /// The identifier is derived from the buttons, so identical button sets share one category.
    static func actionCategory(for content: UNNotificationContent) -> UNNotificationCategory? {
        guard content.categoryIdentifier.isEmpty else { return nil }
        let buttons = actions(content.userInfo[actionsKey])
        guard !buttons.isEmpty else { return nil }
        let actions = buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) }
        let key = buttons.map { "\($0.id)\u{1F}\($0.title)" }.joined(separator: "\u{1E}")
        return UNNotificationCategory(
            identifier: "herald.actions.\(fnv1a(key))", actions: actions, intentIdentifiers: [], options: [.customDismissAction]
        )
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

    /// Returns `content` with the push's `image_url` attached, or `content` unchanged when there is no
    /// https image, the download fails or times out, or the file is not a supported image.
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

    /// The `image_url` value when it is an https URL.
    public static func imageURL(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let text = userInfo[imageKey] as? String, let url = URL(string: text), url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    static func downloadAttachment(from url: URL, timeout: TimeInterval, session: URLSession) async -> UNNotificationAttachment? {
        var mutableRequest = URLRequest(url: url)
        mutableRequest.timeoutInterval = timeout
        let request = mutableRequest
        do {
            let (data, response) = try await withTimeout(timeout) { try await session.data(for: request) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                !data.isEmpty, data.count <= maxBytes,
                let ext = fileExtension(mimeType: http.mimeType, url: url)
            else { return nil }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("image.\(ext)")
            try data.write(to: file)
            // The system moves the file into its own store, so nothing is left to clean up on success.
            return try UNNotificationAttachment(identifier: "herald-image", url: file)
        } catch {
            return nil
        }
    }

    /// The system picks the attachment type from the file extension.
    static func fileExtension(mimeType: String?, url: URL) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        default:
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) ? ext : nil
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
