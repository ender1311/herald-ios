import XCTest
@testable import HeraldSDK

/// Controller rulings shared by both SDKs (Task 4 review, fix round 1).
final class FixRoundOneTests: XCTestCase {
    private func messages() throws -> FakeResponse { FakeResponse(status: 200, body: try fixtureData("messages")) }

    // Ruling a: a trigger while the app is inactive stays pending (persisted) and shows on activation.
    func testTriggerWhileInactiveShowsOnActivationEvenAfterRelaunch() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.ensureSession()  // its sync uses the default empty response
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.pushResponse(messageId: "dec_1", decisionId: "dec_1", action: "open", buttonId: nil)
        await core.drain()
        XCTAssertTrue(harness.output.offered.isEmpty, "not shown while inactive")
        let pending = await core.state.pendingMessageIds
        XCTAssertEqual(pending, ["msg_6"])

        let relaunched = harness.makeCore()  // same directory: pending list and message cache persist
        await relaunched.appDidBecomeActive()  // same session continues; messages come from the cache
        await relaunched.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_6"])
        let shown = await relaunched.state.lastShown["anonymous"]?["msg_6"]
        XCTAssertNotNil(shown)
        let after = await relaunched.state.pendingMessageIds
        XCTAssertFalse(after.contains("msg_6"))
    }

    // Ruling a: within the minimum interval a second message waits instead of being lost.
    func testMinimumIntervalKeepsMessagePending() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.track("workout_completed", properties: ["minutes": 30])
        await core.drain()
        await harness.output.closeAll()
        for _ in 0..<2000 where await core.showingId != nil { await Task.yield() }

        harness.clock.advance(10)
        await core.pushResponse(messageId: "d", decisionId: nil, action: "open", buttonId: nil)
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_2"], "interval still running")

        harness.clock.advance(21)
        await core.showPendingIfPossible()  // what the interval retry timer does
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_2", "msg_6"])
        let lastDisplay = await core.state.lastDisplayAt
        XCTAssertEqual(lastDisplay, t0.addingTimeInterval(31), "min-interval clock is persisted")
    }

    // Minor 8: a stale onClose for another message does not free the slot.
    func testStaleCloseDoesNotFreeSlot() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.fire(.sessionStart)
        await core.drain()
        await core.messageClosed(id: "msg_other")
        let showing = await core.showingId
        XCTAssertEqual(showing, "msg_5")
    }

    // Ruling d: history is keyed by user, survives switches, and only wipeData clears it.
    func testReEligibilityPerUserSurvivesSwitchUntilWipe() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.identify(userId: "u1", traits: [:])
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.track("workout_completed", properties: ["minutes": 30])  // msg_2, once
        await core.drain()
        await harness.output.closeAll()
        for _ in 0..<2000 where await core.showingId != nil { await Task.yield() }

        harness.clock.advance(60)
        await core.identify(userId: "u2", traits: [:])
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.track("workout_completed", properties: ["minutes": 30])
        await core.drain()
        XCTAssertEqual(harness.output.offered.filter { $0.id == "msg_2" }.count, 2, "u2 has its own history")
        await harness.output.closeAll()
        for _ in 0..<2000 where await core.showingId != nil { await Task.yield() }

        harness.clock.advance(60)
        await core.identify(userId: "u1", traits: [:])
        await core.drain()
        harness.transport.enqueueMessages(try messages())
        await core.syncMessages()
        await core.track("workout_completed", properties: ["minutes": 30])
        await core.drain()
        XCTAssertEqual(harness.output.offered.filter { $0.id == "msg_2" }.count, 2, "u1 already saw it once")
        let history = await core.state.lastShown
        XCTAssertNotNil(history["u1"]?["msg_2"])
        XCTAssertNotNil(history["u2"]?["msg_2"])

        await core.wipeData()
        let wiped = await core.state.lastShown
        XCTAssertTrue(wiped.isEmpty)
    }

    // Ruling f: a push subscription recorded before the token is sent after it.
    func testPushSubscriptionWaitsForToken() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setSubscription(.push, .optedIn)
        await core.setSubscription(.email, .subscribed)
        await core.setPushToken(hex: "abcd")
        await core.drain()
        await core.flushNow()
        let types = try harness.transport.batchBodies().first?.objectValue?["events"]?.arrayValue?.compactMap { event -> String? in
            guard let object = event.objectValue, let type = object["type"]?.stringValue else { return nil }
            return type == "subscription" ? "subscription:\(object["channel"]?.stringValue ?? "")" : type
        }
        XCTAssertEqual(types, ["session_start", "subscription:email", "push_token", "subscription:push"])
        let deferred = await core.state.deferredPushSubscription
        XCTAssertNil(deferred)
    }

    // Ruling b: invalid calls are rejected locally and never queued.
    func testInvalidCallsAreNeverQueued() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("ok", properties: [:])
        let baseline = await core.queuedCount
        let message = InAppMessage(id: "m", type: .modal)
        let card = ContentCard(id: String(repeating: "c", count: 201), type: .classic)

        await core.track(String(repeating: "\u{1F600}", count: 128), properties: [:])
        await core.track("x", properties: [String(repeating: "k", count: 256): 1])
        await core.screen("", properties: [:])
        await core.trackPurchase(productId: "p", price: 1, currency: "US", quantity: 1, properties: [:])
        await core.trackPurchase(productId: "p", price: .infinity, currency: "USD", quantity: 1, properties: [:])
        await core.trackPurchase(productId: "p", price: 1, currency: "USD", quantity: 0, properties: [:])
        await core.identify(userId: String(repeating: "u", count: 201), traits: [:])
        await core.identify(userId: "u", traits: ["bad": ["a": 1]])
        await core.logMessageClick(message, buttonId: "")
        await core.logCardClick(card)
        await core.pushResponse(messageId: "m", decisionId: String(repeating: "d", count: 201), action: "open", buttonId: nil)
        await core.setPushToken(hex: "")
        let after = await core.queuedCount
        XCTAssertEqual(after, baseline)
        let user = await core.state.userId
        XCTAssertNil(user)

        await core.setAttributes(["$email": nil])
        await core.logMessageClick(message, buttonId: "b1")
        let accepted = await core.queuedCount
        XCTAssertEqual(accepted, baseline + 2)
    }

    // Major 6: backgrounding returns at once; recording continues while the flush is in flight, and the
    // returned task (what holds the background assertion) ends only when the upload ends.
    func testBackgroundFlushDoesNotBlockRecording() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("before", properties: [:])
        await core.drain()
        harness.transport.setBatchDelay(milliseconds: 300)

        let flush = await core.appDidEnterBackground()
        let joined = await core.startFlush()
        await core.track("during", properties: [:])
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 3, "recorded and persisted while the upload is in flight")
        XCTAssertTrue(harness.transport.batchRequests.count <= 1)

        await flush.value
        _ = await joined.value
        // One flush loop: batch 1, then the event recorded meanwhile. A joined request adds no parallel upload.
        XCTAssertEqual(harness.transport.batchRequests.count, 2)
        let remaining = await core.queuedCount
        XCTAssertEqual(remaining, 0, "the background task covers everything queued before the upload ended")
    }
}
