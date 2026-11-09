import Foundation

/// An in-app message synced from Herald and evaluated on the device.
/// The SDK decides when a message is eligible; a presenter (the `HeraldUI` module, or your own)
/// draws it. Style fields that are nil mean "use the app theme".
public struct InAppMessage: Sendable, Hashable, Identifiable {
    public enum MessageType: String, Sendable, Hashable, CaseIterable {
        case slideup, modal, full, html
    }

    public enum SlideFrom: String, Sendable, Hashable {
        case top, bottom
    }

    public enum ButtonAction: Sendable, Hashable {
        /// Close the message.
        case close
        /// Open a deep link or web URL, then close the message.
        case deeplink(URL)
    }

    public struct Button: Sendable, Hashable, Identifiable {
        public let id: String
        public let text: String
        public let action: ButtonAction

        public init(id: String, text: String, action: ButtonAction) {
            self.id = id
            self.text = text
            self.action = action
        }
    }

    public struct Content: Sendable, Hashable {
        public let header: String?
        public let body: String?
        public let imageUrl: URL?
        public let buttons: [Button]
        /// HTML document for `.html` messages.
        public let html: String?
        public let slideFrom: SlideFrom?
        /// Auto-dismiss delay in seconds; nil keeps the message until the user acts.
        public let dismissAfterSeconds: Double?

        public init(
            header: String? = nil, body: String? = nil, imageUrl: URL? = nil, buttons: [Button] = [],
            html: String? = nil, slideFrom: SlideFrom? = nil, dismissAfterSeconds: Double? = nil
        ) {
            self.header = header
            self.body = body
            self.imageUrl = imageUrl
            self.buttons = buttons
            self.html = html
            self.slideFrom = slideFrom
            self.dismissAfterSeconds = dismissAfterSeconds
        }
    }

    /// Per-message colors (hex strings such as `#101828`) and corner radius. Nil means "use the app theme".
    public struct Style: Sendable, Hashable {
        public let backgroundColor: String?
        public let textColor: String?
        public let buttonColor: String?
        public let buttonTextColor: String?
        public let cornerRadius: Double?

        public init(
            backgroundColor: String? = nil, textColor: String? = nil, buttonColor: String? = nil,
            buttonTextColor: String? = nil, cornerRadius: Double? = nil
        ) {
            self.backgroundColor = backgroundColor
            self.textColor = textColor
            self.buttonColor = buttonColor
            self.buttonTextColor = buttonTextColor
            self.cornerRadius = cornerRadius
        }
    }

    public let id: String
    public let type: MessageType
    /// Higher wins when several messages match one trigger.
    public let priority: Int
    public let trigger: InAppTrigger
    public let reEligibility: InAppReEligibility
    public let expiresAt: Date?
    public let content: Content
    public let style: Style
    public let decisionId: String?

    public init(
        id: String, type: MessageType, priority: Int = 0, trigger: InAppTrigger = .sessionStart,
        reEligibility: InAppReEligibility = .once, expiresAt: Date? = nil, content: Content = Content(),
        style: Style = Style(), decisionId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.priority = priority
        self.trigger = trigger
        self.reEligibility = reEligibility
        self.expiresAt = expiresAt
        self.content = content
        self.style = style
        self.decisionId = decisionId
    }
}

public enum InAppTrigger: Sendable, Hashable {
    case sessionStart
    /// A custom event tracked with `track(_:properties:)`; every filter must match.
    case event(name: String, propertyFilters: [PropertyFilter])
    case pushOpen
}

public struct PropertyFilter: Sendable, Hashable {
    public enum Operator: String, Sendable, Hashable, CaseIterable {
        case eq, neq, gt, gte, lt, lte, contains, exists
    }

    public let key: String
    public let op: Operator
    public let value: HeraldValue

    public init(key: String, op: Operator, value: HeraldValue = .null) {
        self.key = key
        self.op = op
        self.value = value
    }
}

public enum InAppReEligibility: Sendable, Hashable {
    /// Shown at most once per user on this device.
    case once
    /// Eligible again this many hours after it was last shown.
    case afterHours(Double)
}

/// What to do with a message whose trigger fired.
public enum InAppMessageDisplayChoice: Sendable {
    /// Show it now.
    case display
    /// Keep it; `Herald.shared.showNext()` shows it later.
    case later
    /// Drop this occurrence. The message stays eligible for its next trigger.
    case discard
}

/// Lets the app hold or drop a message before it appears.
@MainActor
public protocol InAppMessageDelegate: AnyObject {
    func shouldDisplay(_ message: InAppMessage) -> InAppMessageDisplayChoice
}

/// Draws in-app messages. `HeraldUI` provides the default implementation; set your own on
/// `Herald.shared.inAppMessagePresenter` to replace it.
///
/// Return true from `present` only when the message is on screen; the SDK then logs the impression and
/// records it as shown. Return false when it cannot show now (for example no active window scene): the
/// message stays pending and is offered again on the next activation, trigger or `showNext()`, and
/// `onClose` must not be called. After returning true, log clicks with `logClick(_:buttonId:)` and call
/// `onClose` exactly once when the message leaves the screen (log a dismissal first with
/// `logDismissal(_:)` if the user dismissed it without clicking).
@MainActor
public protocol InAppMessagePresenter: AnyObject {
    func present(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) -> Bool
}

// MARK: - Decoding

extension InAppMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, type, priority, trigger, reEligibility, expiresAt, content, style, decisionId
    }

    /// Strict on the fields that drive behavior (id, type, trigger, re-eligibility), lenient on the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let type = MessageType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown message type \(rawType)")
        }
        let content = c.lenient(Content.self, .content) ?? Content()
        if type == .html, (content.html ?? "").isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .content, in: c, debugDescription: "html message without html")
        }
        self.init(
            id: try c.decode(String.self, forKey: .id),
            type: type,
            priority: c.lenient(Int.self, .priority) ?? 0,
            trigger: try c.decode(InAppTrigger.self, forKey: .trigger),
            reEligibility: try c.decodeIfPresent(InAppReEligibility.self, forKey: .reEligibility) ?? .once,
            expiresAt: c.lenientDate(.expiresAt),
            content: content,
            style: c.lenient(Style.self, .style) ?? Style(),
            decisionId: c.lenient(String.self, .decisionId)
        )
    }
}

extension InAppTrigger: Decodable {
    private enum CodingKeys: String, CodingKey { case type, event, propertyFilters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "session_start": self = .sessionStart
        case "push_open": self = .pushOpen
        case "event":
            self = .event(
                name: try c.decode(String.self, forKey: .event),
                // An unknown operator fails the whole message: it cannot be evaluated safely.
                propertyFilters: try c.decodeIfPresent([PropertyFilter].self, forKey: .propertyFilters) ?? []
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown trigger \(type)")
        }
    }
}

extension PropertyFilter: Decodable {
    private enum CodingKeys: String, CodingKey { case key, op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawOp = try c.decode(String.self, forKey: .op)
        guard let op = Operator(rawValue: rawOp) else {
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "Unknown operator \(rawOp)")
        }
        self.init(
            key: try c.decode(String.self, forKey: .key),
            op: op,
            value: c.lenient(HeraldValue.self, .value) ?? .null
        )
    }
}

extension InAppReEligibility: Decodable {
    private enum CodingKeys: String, CodingKey { case mode, hours }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decode(String.self, forKey: .mode)
        switch mode {
        case "once": self = .once
        case "after_hours": self = .afterHours(try c.decode(Double.self, forKey: .hours))
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "Unknown mode \(mode)")
        }
    }
}

extension InAppMessage.Content: Decodable {
    private enum CodingKeys: String, CodingKey {
        case header, body, imageUrl, buttons, html, slideFrom, dismissAfterSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let buttons = (c.lenient([Lossy<InAppMessage.Button>].self, .buttons) ?? []).compactMap(\.value)
        self.init(
            header: c.lenient(String.self, .header),
            body: c.lenient(String.self, .body),
            imageUrl: c.lenientURL(.imageUrl),
            buttons: buttons,
            html: c.lenient(String.self, .html),
            slideFrom: c.lenient(String.self, .slideFrom).flatMap(InAppMessage.SlideFrom.init(rawValue:)),
            dismissAfterSeconds: c.lenient(Double.self, .dismissAfterSeconds)
        )
    }
}

extension InAppMessage.Button: Decodable {
    private enum CodingKeys: String, CodingKey { case id, text, action }
    private enum ActionKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var action = InAppMessage.ButtonAction.close
        if let a = try? c.nestedContainer(keyedBy: ActionKeys.self, forKey: .action),
            a.lenient(String.self, .type) == "deeplink", let url = a.lenientURL(.value)
        {
            action = .deeplink(url)
        }
        self.init(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text), action: action)
    }
}

extension InAppMessage.Style: Decodable {
    private enum CodingKeys: String, CodingKey {
        case backgroundColor, textColor, buttonColor, buttonTextColor, cornerRadius
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backgroundColor: c.lenient(String.self, .backgroundColor),
            textColor: c.lenient(String.self, .textColor),
            buttonColor: c.lenient(String.self, .buttonColor),
            buttonTextColor: c.lenient(String.self, .buttonTextColor),
            cornerRadius: c.lenient(Double.self, .cornerRadius)
        )
    }
}

/// Decodes an array element without failing the array: malformed items become nil.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            Log.warning("Skipping malformed \(T.self): \(error)")
            value = nil
        }
    }
}
