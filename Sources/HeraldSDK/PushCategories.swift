#if os(iOS)
import UserNotifications

/// A notification category with up to three action buttons.
///
/// A push shows these buttons when its APNs payload names the category in the standard
/// `aps.category` key. A tapped button reaches `Herald.shared.handleNotificationResponse(_:)` with the
/// button `id` as its action identifier, which Herald logs as a `button` interaction and then opens
/// the push's `deeplink`.
public struct HeraldPushCategory: Sendable, Hashable {
    public struct Button: Sendable, Hashable {
        public let id: String
        public let title: String
        /// Bring the app to the foreground when tapped (needed to open a deep link).
        public let opensApp: Bool
        /// Show the button in red.
        public let destructive: Bool

        public init(id: String, title: String, opensApp: Bool = true, destructive: Bool = false) {
            self.id = id
            self.title = title
            self.opensApp = opensApp
            self.destructive = destructive
        }
    }

    public static let maxButtons = 3

    public let id: String
    /// At most `maxButtons`; extra buttons are dropped.
    public let buttons: [Button]

    public init(id: String, buttons: [Button]) {
        self.id = id
        self.buttons = Array(buttons.prefix(Self.maxButtons))
    }

    var notificationCategory: UNNotificationCategory {
        let actions = buttons.map { button in
            var options: UNNotificationActionOptions = []
            if button.opensApp { options.insert(.foreground) }
            if button.destructive { options.insert(.destructive) }
            return UNNotificationAction(identifier: button.id, title: button.title, options: options)
        }
        // customDismissAction: a swipe-away reaches handleNotificationResponse as a dismissal.
        return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [.customDismissAction])
    }
}

extension Herald {
    /// Registers categories for push action buttons. Categories the app registered with other ids are
    /// kept; a category with the same id is replaced. Call at launch, before pushes arrive.
    public func registerPushCategories(_ categories: [HeraldPushCategory]) {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = Set(categories.map(\.id))
            let kept = await center.notificationCategories().filter { !ids.contains($0.identifier) }
            center.setNotificationCategories(kept.union(categories.map(\.notificationCategory)))
        }
    }
}
#endif
