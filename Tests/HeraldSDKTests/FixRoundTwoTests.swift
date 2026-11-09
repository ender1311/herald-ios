import os
import XCTest
@testable import HeraldSDK

/// Presenter stand-in that suspends `offer` until the test answers, to interleave calls with the hand-off.
final class PausingOutput: CoreOutput {
    private let waiting = OSAllocatedUnfairLock<CheckedContinuation<InAppMessageDisplayChoice?, Never>?>(initialState: nil)

    var isWaiting: Bool { waiting.withLock { $0 != nil } }

    func answer(_ choice: InAppMessageDisplayChoice?) {
        let continuation = waiting.withLock { value -> CheckedContinuation<InAppMessageDisplayChoice?, Never>? in
            defer { value = nil }
            return value
        }
        continuation?.resume(returning: choice)
    }

    func cardsChanged(_ cards: [ContentCard]) async {}

    func offer(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) async -> InAppMessageDisplayChoice? {
        await withCheckedContinuation { continuation in waiting.withLock { $0 = continuation } }
    }
}

final class FixRoundTwoTests: XCTestCase {
    private func types(_ harness: CoreHarness) throws -> [String] {
        try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }.compactMap { event in
            guard let object = event.objectValue, let type = object["type"]?.stringValue else { return nil }
            if type == "subscription" { return "subscription:\(object["channel"]?.stringValue ?? ""):\(object["state"]?.stringValue ?? "")" }
            return type
        }
    }

    // N1: a denied permission (no token will ever come) still reaches the server, and cancels a deferred opt-in.
    func testPushOptOutIsSentWithoutToken() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setSubscription(.push, .optedIn)  // deferred: no token yet
        await core.setSubscription(.push, .unsubscribed)  // what requestPushAuthorization sends on denial
        await core.drain()
        await core.flushNow()
        XCTAssertEqual(try types(harness), ["session_start", "subscription:push:unsubscribed"])
        let deferred = await core.state.deferredPushSubscription
        XCTAssertNil(deferred)
    }

    // N1: a deferred opt-in does not carry over to another user.
    func testDeferredOptInClearedOnUserChange() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u1", traits: [:])
        await core.setSubscription(.push, .optedIn)
        await core.reset()
        let deferred = await core.state.deferredPushSubscription
        XCTAssertNil(deferred)
        await core.setPushToken(hex: "abcd")
        await core.drain()
        await core.flushNow()
        XCTAssertFalse(try types(harness).contains { $0.hasPrefix("subscription:push") })
    }

    // N2: a redelivered open for the same decision counts once and fires push_open once.
    func testPushOpenIsDedupedByDecisionId() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.pushResponse(messageId: "dec_1", decisionId: "dec_1", action: "open", buttonId: nil)
        await core.pushResponse(messageId: "dec_1", decisionId: "dec_1", action: "open", buttonId: nil)
        let relaunched = harness.makeCore()
        await relaunched.pushResponse(messageId: "dec_1", decisionId: "dec_1", action: "open", buttonId: nil)
        await relaunched.pushResponse(messageId: "dec_2", decisionId: "dec_2", action: "open", buttonId: nil)
        await relaunched.pushResponse(messageId: "dec_2", decisionId: "dec_2", action: "button", buttonId: "b")
        await relaunched.drain()
        await relaunched.flushNow()
        XCTAssertEqual(try types(harness).filter { $0 == "interaction" }.count, 3, "dec_1 open, dec_2 open, dec_2 button")

        for n in 0..<60 { await relaunched.pushResponse(messageId: "d\(n)", decisionId: "d\(n)", action: "open", buttonId: nil) }
        let recent = await relaunched.state.recentPushOpens
        XCTAssertEqual(recent.count, HeraldCore.maxRecentPushOpens)
        XCTAssertEqual(recent.last, "d59")
    }

    // Fix round 1 (Task 5): a button tap logs the push open, then the button, once each per decision.
    func testPushButtonLogsOpenThenButtonOnce() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.pushResponse(messageId: "dec_3", decisionId: "dec_3", action: "button", buttonId: "b1")
        await core.pushResponse(messageId: "dec_3", decisionId: "dec_3", action: "button", buttonId: "b1")
        await core.pushResponse(messageId: "dec_3", decisionId: "dec_3", action: "open", buttonId: nil)
        await core.drain()
        await core.flushNow()
        let actions = try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap { $0.objectValue }.filter { $0["type"]?.stringValue == "interaction" }
            .map { "\($0["action"]?.stringValue ?? ""):\($0["buttonId"]?.stringValue ?? "")" }
        XCTAssertEqual(actions, ["open:", "button:b1"])
    }

    // N4: an invalid $email or $phone is dropped on its own; the rest of the call is queued.
    func testInvalidContactAttributeDropsOnlyThatKey() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setAttributes(["plan": "free", "$email": "nope", "$phone": "123"])
        await core.setAttributes(["$email": "still-bad"])  // nothing left: no event
        await core.drain()
        await core.flushNow()
        let attributes = try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap { $0.objectValue }.filter { $0["type"] == "attributes" }
        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(attributes.first?["attributes"], ["plan": "free"])
    }

    private func pausedCore() async throws -> (CoreHarness, HeraldCore, PausingOutput) {
        let harness = CoreHarness()
        let output = PausingOutput()
        var configuration = HeraldConfiguration(appKey: "pk", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushAt = 100_000
        let clock = harness.clock
        let ids = harness.ids
        let core = HeraldCore(
            configuration: configuration, storage: Storage(directory: harness.directory), transport: harness.transport,
            deviceInfo: FixtureDeviceInfo(), output: output, now: { clock.now }, random: { 1 }, makeId: { ids.next() },
            bundleId: "com.lumen.app"
        )
        await core.appDidBecomeActive()
        await core.drain()
        harness.transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))
        await core.syncMessages()
        await core.fire(.sessionStart)
        for _ in 0..<2000 where !output.isWaiting { await Task.yield() }
        XCTAssertTrue(output.isWaiting)
        return (harness, core, output)
    }

    // Minor 7 / N3: identify during the hand-off; the message is on screen, so it is recorded, under the
    // user captured at hand-off.
    func testIdentifyDuringHandOffRecordsUnderCapturedUser() async throws {
        let (_, core, output) = try await pausedCore()
        await core.identify(userId: "u1", traits: [:])
        output.answer(.display)
        for _ in 0..<2000 where await core.state.lastShown.isEmpty { await Task.yield() }
        let history = await core.state.lastShown
        XCTAssertNotNil(history["anonymous"]?["msg_5"])
        XCTAssertNil(history["u1"]?["msg_5"])
        let showing = await core.showingId
        XCTAssertEqual(showing, "msg_5", "slot stays taken until onClose")
    }

    // Minor 7: wipeData during the hand-off frees the slot; the late answer records nothing.
    func testWipeDuringHandOffRecordsNothing() async throws {
        let (_, core, output) = try await pausedCore()
        await core.wipeData()
        output.answer(.display)
        for _ in 0..<200 { await Task.yield() }
        await core.drain()
        let history = await core.state.lastShown
        XCTAssertTrue(history.isEmpty)
        let showing = await core.showingId
        XCTAssertNil(showing)
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0, "no impression after wipe")
    }
}
