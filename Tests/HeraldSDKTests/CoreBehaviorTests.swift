import XCTest
@testable import HeraldSDK

final class CoreBehaviorTests: XCTestCase {
    private func messagesResponse(etag: String? = nil) throws -> FakeResponse {
        FakeResponse(status: 200, headers: etag.map { ["ETag": $0] } ?? [:], body: try fixtureData("messages"))
    }

    func testETag304KeepsCache() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        harness.transport.enqueueMessages(try messagesResponse(etag: "\"v1\""))
        await core.syncMessages()
        harness.transport.enqueueMessages(FakeResponse(status: 304))
        await core.syncMessages()
        await core.drain()

        let requests = harness.transport.messageRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(requests[0].url?.query?.contains("deviceId="), true)
        let cards = await core.visibleCards()
        XCTAssertEqual(cards.map(\.id), ["msg_1", "msg_3", "msg_4"])
        XCTAssertEqual(harness.output.lastCards?.count, 3)

        // The cache also survives a relaunch.
        let relaunched = harness.makeCore()
        let cached = await relaunched.visibleCards()
        XCTAssertEqual(cached.count, 3)
        let etag = await relaunched.state.messagesETag
        XCTAssertEqual(etag, "\"v1\"")
    }

    func testSetUserTokenAfterIdentifySyncsWithTheToken() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u1", traits: [:])
        await core.drain()
        XCTAssertNil(harness.transport.messageRequests.last?.value(forHTTPHeaderField: "x-herald-user-token"))
        await core.setUserToken("tok1")
        await core.drain()
        XCTAssertEqual(harness.transport.messageRequests.last?.value(forHTTPHeaderField: "x-herald-user-token"), "tok1")
        let count = harness.transport.messageRequests.count
        await core.setUserToken("tok1")  // unchanged: no extra request
        await core.drain()
        XCTAssertEqual(harness.transport.messageRequests.count, count)
    }

    func testDismissedCardStaysHidden() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.ensureSession()
        await core.drain()
        harness.transport.enqueueMessages(try messagesResponse())
        await core.syncMessages()
        let visible = await core.visibleCards()
        let card = try XCTUnwrap(visible.first)
        await core.logCardDismissal(card)
        harness.transport.enqueueMessages(try messagesResponse())  // server has not processed the dismissal yet
        await core.syncMessages()
        await core.drain()
        let ids = await core.visibleCards().map(\.id)
        XCTAssertEqual(ids, ["msg_3", "msg_4"])
        XCTAssertEqual(harness.output.lastCards?.map(\.id), ["msg_3", "msg_4"])
    }

    func testResetClearsUserState() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.identify(userId: "u1", traits: [:])
        await core.setUserToken("tok1")
        await core.drain()
        harness.transport.enqueueMessages(try messagesResponse(etag: "\"u1\""))
        await core.syncMessages()
        await core.fire(.sessionStart)  // shows msg_5 and records it for u1
        await core.drain()
        let shownBefore = await core.state.lastShown["u1"]?["msg_5"]
        XCTAssertNotNil(shownBefore)
        let oldSession = await core.state.session?.id

        harness.clock.advance(60)
        await core.reset()
        await core.drain()

        let state = await core.state
        XCTAssertNil(state.userId)
        XCTAssertNil(state.userToken)
        XCTAssertNil(state.messagesETag)
        XCTAssertEqual(state.lastShown["u1"]?["msg_5"], shownBefore, "in-app history survives reset")
        XCTAssertNotEqual(state.session?.id, oldSession, "reset starts a new session")
        let cards = await core.visibleCards()
        XCTAssertTrue(cards.isEmpty)
        let messages = await core.engine.messages
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(harness.output.lastCards, [])

        await core.flushNow()
        let requests = harness.transport.batchRequests
        let bodies = try harness.transport.batchBodies()
        let last = try XCTUnwrap(bodies.last?.objectValue)
        XCTAssertEqual(last["userId"], .null)
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "x-herald-user-token"))
        let types = last["events"]?.arrayValue?.compactMap { $0.objectValue?["type"]?.stringValue }
        XCTAssertEqual(types, ["session_start"])
        let firstTypes = bodies.first?.objectValue?["events"]?.arrayValue?.compactMap { $0.objectValue?["type"]?.stringValue }
        XCTAssertEqual(firstTypes?.last, "session_end", "the old session ends under the old user")
        // After reset, the anonymous sync carries no user id.
        let lastSync = try XCTUnwrap(harness.transport.messageRequests.last)
        XCTAssertEqual(lastSync.url?.query?.contains("userId"), false)

        // Logging back in restores u1's history: msg_5 (every 24 h) is not eligible again yet.
        await core.identify(userId: "u1", traits: [:])
        let restored = await core.engine.lastShown["msg_5"]
        XCTAssertEqual(restored, shownBefore)
    }

    /// Active app with the fixture messages synced (the session's own sync used the default empty response).
    private func activeCoreWithMessages(_ harness: CoreHarness) async throws -> HeraldCore {
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.drain()
        harness.transport.enqueueMessages(try messagesResponse())
        await core.syncMessages()
        return core
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<2000 where !(await condition()) { await Task.yield() }
    }

    func testTrackTriggersHighestPriorityMessageAndLogsImpression() async throws {
        let harness = CoreHarness()
        let core = try await activeCoreWithMessages(harness)

        await core.track("workout_completed", properties: ["minutes": 10])
        await core.drain()
        XCTAssertTrue(harness.output.offered.isEmpty, "filter minutes > 20 does not match")

        await core.track("workout_completed", properties: ["minutes": 32])
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_2"])

        // While it is on screen nothing else shows, even past the minimum interval: the push-open
        // message waits in the pending list.
        harness.clock.advance(60)
        await core.pushResponse(messageId: "dec_x", decisionId: "dec_x", action: "open", buttonId: nil)
        await core.drain()
        XCTAssertEqual(harness.output.offered.count, 1)
        let pending = await core.state.pendingMessageIds
        XCTAssertEqual(pending, ["msg_6"])

        // Closing msg_2 shows the pending message.
        await harness.output.closeAll()
        await waitUntil { harness.output.offered.count == 2 }
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_2", "msg_6"])

        await core.flushNow()
        let events = try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
        let interactions = events.compactMap(\.objectValue).filter { $0["type"] == "interaction" }
        XCTAssertTrue(interactions.contains { $0["messageId"] == "msg_2" && $0["action"] == "impression" && $0["decisionId"] == "dec_2" && $0["kind"] == "in_app" })
        XCTAssertTrue(interactions.contains { $0["kind"] == "push" && $0["action"] == "open" })
        let shown = await core.state.lastShown["anonymous"]?["msg_2"]
        XCTAssertNotNil(shown, "once-only message is recorded as shown")
    }

    func testDelegateLaterDiscardAndNoPresenter() async throws {
        let harness = CoreHarness()
        let core = try await activeCoreWithMessages(harness)

        harness.output.setChoice(.discard)
        await core.fire(.sessionStart)
        await core.drain()
        var shown = await core.state.lastShown["anonymous"]?["msg_5"]
        XCTAssertNil(shown, "discard does not mark the message shown")
        var pending = await core.state.pendingMessageIds
        XCTAssertTrue(pending.isEmpty, "discard drops this occurrence")

        harness.output.setChoice(.later)
        await core.fire(.sessionStart)
        await core.drain()
        pending = await core.state.pendingMessageIds
        XCTAssertEqual(pending, ["msg_5"], ".later keeps it pending")
        harness.output.setChoice(.display)
        await core.showNext()
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_5", "msg_5", "msg_5"])
        shown = await core.state.lastShown["anonymous"]?["msg_5"]
        XCTAssertNotNil(shown)

        // No presenter: the message is not consumed and shows once one is set.
        harness.output.setChoice(nil)
        await harness.output.closeAll()
        await waitUntil { await core.showingId == nil }
        harness.clock.advance(31)
        await core.track("workout_completed", properties: ["minutes": 40])
        await core.drain()
        var msg2Shown = await core.state.lastShown["anonymous"]?["msg_2"]
        XCTAssertNil(msg2Shown)
        pending = await core.state.pendingMessageIds
        XCTAssertEqual(pending, ["msg_2"])

        harness.output.setChoice(.display)
        await core.showPendingIfPossible()  // what setting a presenter does
        await core.drain()
        XCTAssertEqual(harness.output.offered.last?.id, "msg_2")
        msg2Shown = await core.state.lastShown["anonymous"]?["msg_2"]
        XCTAssertNotNil(msg2Shown)
    }

    func testDisabledSDKRecordsNothing() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setEnabled(false)
        await core.track("a", properties: [:])
        await core.identify(userId: "u", traits: [:])
        await core.flushNow()
        await core.drain()
        let count = await core.queuedCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(harness.transport.requests.isEmpty)
    }

    func testWipeDataClearsEverythingAndDisables() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u", traits: [:])
        await core.drain()
        let oldDevice = await core.state.deviceId
        await core.wipeData()
        await core.drain()
        let state = await core.state
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.userId)
        XCTAssertNotEqual(state.deviceId, oldDevice)
        let count = await core.queuedCount
        XCTAssertEqual(count, 0)
        let relaunched = harness.makeCore()
        let relaunchedState = await relaunched.state
        XCTAssertFalse(relaunchedState.enabled)
        XCTAssertNil(relaunchedState.userId)
    }

    func testSessionTimeoutEndsAndStartsSession() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("a", properties: [:])
        harness.clock.advance(100)
        await core.track("b", properties: [:])
        harness.clock.advance(31 * 60)
        await core.track("c", properties: [:])
        await core.drain()
        await core.flushNow()
        let events = try XCTUnwrap(harness.transport.batchBodies().first?.objectValue?["events"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(events.compactMap { $0["type"]?.stringValue }, ["session_start", "track", "track", "session_end", "session_start", "track"])
        XCTAssertEqual(events[3]["durationSeconds"], 100)
        XCTAssertEqual(events[3]["sessionId"], events[0]["sessionId"])
        XCTAssertNotEqual(events[4]["sessionId"], events[0]["sessionId"])
    }

    func testPushTokenIsResentForANewUser() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setPushToken(hex: "abcd")
        await core.identify(userId: "u1", traits: [:])
        await core.drain()
        await core.flushNow()
        let events = try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
        let tokens = events.compactMap(\.objectValue).filter { $0["type"] == "push_token" }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens.first?["environment"], "production")
        XCTAssertEqual(tokens.first?["bundleId"], "com.lumen.app")
    }
}

final class SyncRaceTests: XCTestCase {
    /// identify while the anonymous sync is in flight must still fetch the identified user's messages.
    func testIdentifyDuringInFlightSyncResyncs() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        harness.transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages-empty")))
        harness.transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))
        async let anonymous: Void = core.syncMessages()
        await core.identify(userId: "u1", traits: [:])
        _ = await anonymous
        await core.drain()
        let syncs = harness.transport.messageRequests
        XCTAssertTrue(syncs.contains { $0.url?.query?.contains("userId=u1") == true })
        let cards = await core.visibleCards()
        XCTAssertEqual(cards.count, 3)
    }
}
