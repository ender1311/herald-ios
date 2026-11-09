import Foundation

/// What happened on the device that may trigger an in-app message.
enum TriggerEvent: Sendable, Equatable {
    case sessionStart
    case event(name: String, properties: [String: HeraldValue])
    case pushOpen
}

/// Pure in-app selection rules: trigger match, expiry, re-eligibility, minimum interval,
/// one message at a time, highest priority wins (ties keep server order).
struct InAppEngine {
    var messages: [InAppMessage] = []
    /// Message id → last time it was shown to the current user.
    var lastShown: [String: Date] = [:]
    var lastDisplayAt: Date?
    var isShowing = false
    var minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func evaluate(trigger: TriggerEvent, now: Date) -> InAppMessage? {
        guard !isShowing else { return nil }
        if let lastDisplayAt, now.timeIntervalSince(lastDisplayAt) < minimumInterval { return nil }
        var best: InAppMessage?
        for message in messages where isEligible(message, now: now) && Self.matches(message.trigger, trigger) {
            if best == nil || message.priority > (best?.priority ?? .min) { best = message }
        }
        return best
    }

    func isEligible(_ message: InAppMessage, now: Date) -> Bool {
        if let expiresAt = message.expiresAt, expiresAt <= now { return false }
        guard let shown = lastShown[message.id] else { return true }
        switch message.reEligibility {
        case .once: return false
        case .afterHours(let hours): return now.timeIntervalSince(shown) >= hours * 3600
        }
    }

    mutating func recordDisplay(_ message: InAppMessage, now: Date) {
        lastShown[message.id] = now
        lastDisplayAt = now
    }

    static func matches(_ trigger: InAppTrigger, _ event: TriggerEvent) -> Bool {
        switch (trigger, event) {
        case (.sessionStart, .sessionStart), (.pushOpen, .pushOpen):
            return true
        case (.event(let name, let filters), .event(let eventName, let properties)):
            return name == eventName && filters.allSatisfy { matches($0, properties) }
        default:
            return false
        }
    }

    static func matches(_ filter: PropertyFilter, _ properties: [String: HeraldValue]) -> Bool {
        let actual = properties[filter.key]
        guard let actual, actual != .null else {
            // A missing property only satisfies "not equal".
            return filter.op == .neq && filter.value != .null
        }
        switch filter.op {
        case .exists: return true
        case .eq: return actual == filter.value
        case .neq: return actual != filter.value
        case .gt, .gte, .lt, .lte:
            guard let lhs = actual.numberValue, let rhs = filter.value.numberValue else { return false }
            switch filter.op {
            case .gt: return lhs > rhs
            case .gte: return lhs >= rhs
            case .lt: return lhs < rhs
            default: return lhs <= rhs
            }
        case .contains:
            switch (actual, filter.value) {
            case (.string(let haystack), .string(let needle)): return haystack.contains(needle)
            case (.array(let items), let needle): return items.contains(needle)
            default: return false
            }
        }
    }
}
