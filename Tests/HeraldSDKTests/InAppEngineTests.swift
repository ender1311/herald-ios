import XCTest
@testable import HeraldSDK

final class InAppEngineTests: XCTestCase {
    private func message(
        _ id: String, priority: Int = 0, trigger: InAppTrigger = .sessionStart,
        reEligibility: InAppReEligibility = .once, expiresAt: Date? = nil
    ) -> InAppMessage {
        InAppMessage(id: id, type: .modal, priority: priority, trigger: trigger, reEligibility: reEligibility, expiresAt: expiresAt)
    }

    func testHighestPriorityWinsAndTiesKeepServerOrder() {
        var engine = InAppEngine(minimumInterval: 30)
        engine.messages = [message("low", priority: 1), message("high", priority: 9), message("high2", priority: 9)]
        XCTAssertEqual(engine.evaluate(trigger: .sessionStart, now: t0)?.id, "high")
    }

    func testMinimumIntervalBetweenMessages() {
        var engine = InAppEngine(minimumInterval: 30)
        engine.messages = [message("a", reEligibility: .afterHours(0)), message("b")]
        let first = engine.evaluate(trigger: .sessionStart, now: t0)
        XCTAssertEqual(first?.id, "a")
        engine.recordDisplay(first!, now: t0)
        XCTAssertNil(engine.evaluate(trigger: .sessionStart, now: t0.addingTimeInterval(29)))
        XCTAssertNotNil(engine.evaluate(trigger: .sessionStart, now: t0.addingTimeInterval(30)))
    }

    func testNeverOverAnotherMessage() {
        var engine = InAppEngine(minimumInterval: 0)
        engine.messages = [message("a")]
        engine.isShowing = true
        XCTAssertNil(engine.evaluate(trigger: .sessionStart, now: t0))
    }

    func testOnceAndAfterHours() {
        var engine = InAppEngine(minimumInterval: 0)
        let once = message("once")
        let daily = message("daily", reEligibility: .afterHours(24))
        engine.messages = [once, daily]
        engine.recordDisplay(once, now: t0)
        engine.recordDisplay(daily, now: t0)
        XCTAssertFalse(engine.isEligible(once, now: t0.addingTimeInterval(365 * 86_400)))
        XCTAssertFalse(engine.isEligible(daily, now: t0.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(engine.isEligible(daily, now: t0.addingTimeInterval(24 * 3600)))
        XCTAssertEqual(engine.evaluate(trigger: .sessionStart, now: t0.addingTimeInterval(24 * 3600))?.id, "daily")
    }

    func testExpiredMessagesAreIgnored() {
        var engine = InAppEngine(minimumInterval: 0)
        engine.messages = [message("old", priority: 5, expiresAt: t0), message("fresh")]
        XCTAssertEqual(engine.evaluate(trigger: .sessionStart, now: t0)?.id, "fresh")
    }

    func testTriggerTypes() {
        var engine = InAppEngine(minimumInterval: 0)
        engine.messages = [message("push", trigger: .pushOpen), message("event", trigger: .event(name: "done", propertyFilters: []))]
        XCTAssertNil(engine.evaluate(trigger: .sessionStart, now: t0))
        XCTAssertEqual(engine.evaluate(trigger: .pushOpen, now: t0)?.id, "push")
        XCTAssertEqual(engine.evaluate(trigger: .event(name: "done", properties: [:]), now: t0)?.id, "event")
        XCTAssertNil(engine.evaluate(trigger: .event(name: "other", properties: [:]), now: t0))
    }

    func testPropertyFilters() {
        let props: [String: HeraldValue] = ["minutes": 32, "plan": "free_trial", "tags": ["a", "b"], "flag": true, "gone": nil]
        func check(_ op: PropertyFilter.Operator, _ key: String, _ value: HeraldValue = .null) -> Bool {
            InAppEngine.matches(PropertyFilter(key: key, op: op, value: value), props)
        }
        XCTAssertTrue(check(.eq, "minutes", 32))
        XCTAssertFalse(check(.eq, "minutes", "32"))
        XCTAssertTrue(check(.neq, "plan", "plus"))
        XCTAssertFalse(check(.neq, "missing", "x"), "a missing property fails every operator, neq included")
        XCTAssertFalse(check(.neq, "gone", "x"), "null counts as missing")
        XCTAssertFalse(check(.contains, "missing", "x"))
        XCTAssertFalse(check(.eq, "missing", .null))
        XCTAssertTrue(check(.gt, "minutes", 20))
        XCTAssertFalse(check(.gt, "minutes", 32))
        XCTAssertTrue(check(.gte, "minutes", 32))
        XCTAssertTrue(check(.lt, "minutes", 33))
        XCTAssertTrue(check(.lte, "minutes", 32))
        XCTAssertFalse(check(.lt, "plan", 5), "comparisons need numbers")
        XCTAssertTrue(check(.contains, "plan", "trial"))
        XCTAssertTrue(check(.contains, "tags", "b"))
        XCTAssertFalse(check(.contains, "tags", "c"))
        XCTAssertTrue(check(.exists, "flag"))
        XCTAssertFalse(check(.exists, "gone"), "null counts as absent")
        XCTAssertFalse(check(.exists, "missing"))
        XCTAssertFalse(check(.gt, "missing", 1))

        let trigger = InAppTrigger.event(
            name: "workout_completed",
            propertyFilters: [PropertyFilter(key: "minutes", op: .gt, value: 20), PropertyFilter(key: "plan", op: .eq, value: "free_trial")]
        )
        XCTAssertTrue(InAppEngine.matches(trigger, .event(name: "workout_completed", properties: props)))
        XCTAssertFalse(InAppEngine.matches(trigger, .event(name: "workout_completed", properties: ["minutes": 10, "plan": "free_trial"])))
    }
}
