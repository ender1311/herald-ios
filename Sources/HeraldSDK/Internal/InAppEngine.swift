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

    /// The message to show for this trigger right now, or nil (nothing matches, or one cannot show yet).
    func evaluate(trigger: TriggerEvent, now: Date) -> InAppMessage? {
        canShow(now: now) ? candidate(for: trigger, now: now) : nil
    }

    /// The highest-priority eligible message matching the trigger, ignoring what is on screen.
    func candidate(for trigger: TriggerEvent, now: Date) -> InAppMessage? {
        best(of: messages.filter { isEligible($0, now: now) && Self.matches($0.trigger, trigger) })
    }

    /// The highest-priority eligible message among pending ids.
    func nextPending(_ ids: [String], now: Date) -> InAppMessage? {
        best(of: messages.filter { ids.contains($0.id) && isEligible($0, now: now) })
    }

    /// Nothing on screen and the minimum interval has passed.
    func canShow(now: Date) -> Bool {
        guard !isShowing else { return false }
        return intervalRemaining(now: now) <= 0
    }

    func intervalRemaining(now: Date) -> TimeInterval {
        guard let lastDisplayAt else { return 0 }
        return minimumInterval - now.timeIntervalSince(lastDisplayAt)
    }

    private func best(of candidates: [InAppMessage]) -> InAppMessage? {
        var best: InAppMessage?
        for message in candidates where best == nil || message.priority > (best?.priority ?? .min) {
            best = message
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
        // A missing (or null) property fails every operator, `exists` included.
        guard let actual, actual != .null else { return false }
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
