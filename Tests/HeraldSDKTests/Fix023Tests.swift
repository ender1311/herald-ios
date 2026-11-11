import XCTest
@testable import HeraldSDK

/// Defects from the 0.2.2 hands-on QA, fixed in 0.2.3.
final class Fix023Tests: XCTestCase {
    // D1: after wipeData() + setEnabled(true) with permission still granted, the SDK asks iOS for the token
    // again and sends push_token then subscribed once it arrives.
    func testReEnableAfterWipeRegistersForPushAgain() async throws {
        var harness = CoreHarness()
        let registrar = CallCounter()
        harness.registerForPush = registrar.call
        let core = harness.makeCore()
        await core.setPushToken(hex: "abcd")
        await core.drain()
        await core.flushNow()
        await core.wipeData()
        await core.drain()
        await core.setEnabled(true)
        await core.drain()
        XCTAssertEqual(registrar.count, 1)
        let deferred = await core.state.deferredPushSubscription
        XCTAssertEqual(deferred, .subscribed, "waits for the token")
        await core.setPushToken(hex: "abcd")  // iOS hands the token back through the app's forwarding
        await core.drain()
        await core.flushNow()
        let last = try XCTUnwrap(harness.transport.batchBodies().last?.objectValue?["events"]?.arrayValue).compactMap(\.objectValue)
        let types = last.compactMap { $0["type"]?.stringValue }
        XCTAssertEqual(Array(types.suffix(2)), ["push_token", "subscription"])
        XCTAssertEqual(last.last?["state"], "subscribed")
    }

    func testReEnableAfterWipeWithoutPermissionDoesNotRegister() async throws {
        var harness = CoreHarness()
        let registrar = CallCounter()
        harness.registerForPush = registrar.call
        let core = harness.makeCore(deviceInfo: DeniedPushDeviceInfo())
        await core.wipeData()
        await core.setEnabled(true)
        await core.drain()
        XCTAssertEqual(registrar.count, 0)
    }

    // D1: each launch while enabled, authorized and without a token asks for the token, without touching
    // the push subscription; a launch with a stored token does not.
    func testLaunchWithoutTokenRegistersButDoesNotResubscribe() async throws {
        var harness = CoreHarness()
        let registrar = CallCounter()
        harness.registerForPush = registrar.call
        let core = harness.makeCore()
        await core.start()
        await core.drain()
        XCTAssertEqual(registrar.count, 1)
        let deferred = await core.state.deferredPushSubscription
        XCTAssertNil(deferred)

        await core.setPushToken(hex: "abcd")
        let relaunched = harness.makeCore()
        await relaunched.start()
        await relaunched.drain()
        XCTAssertEqual(registrar.count, 1, "a stored token needs no registration")
    }

    private func impressions(_ harness: CoreHarness) throws -> [String] {
        let events: [[String: HeraldValue]] = try harness.transport.batchBodies()
            .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }.compactMap(\.objectValue)
        let shown = events.filter { $0["type"] == .string("interaction") && $0["action"] == .string("impression") }
        return shown.compactMap { $0["messageId"]?.stringValue }
    }

    private func coreWithCards(_ harness: CoreHarness) async throws -> HeraldCore {
        let core = harness.makeCore()
        await core.debugApply(try MessagesPayload.decode(fixtureData("messages")))
        return core
    }

    // D3: one impression per card per session, across feed rebuilds and relaunches; a new session logs again.
    func testCardImpressionLoggedOncePerSession() async throws {
        let harness = CoreHarness()
        let core = try await coreWithCards(harness)
        let visible = await core.visibleCards()
        let card = try XCTUnwrap(visible.first)
        await core.logCardImpression(card)
        await core.logCardImpression(card)  // a second feed, or a filter change
        let relaunched = try await coreWithCards(harness)
        await relaunched.logCardImpression(card)
        await relaunched.flushNow()
        XCTAssertEqual(try impressions(harness), [card.id])

        harness.clock.advance(31 * 60)  // the session times out
        await relaunched.logCardImpression(card)
        await relaunched.flushNow()
        XCTAssertEqual(try impressions(harness), [card.id, card.id])
    }
}
