import XCTest
@testable import HeraldSDK

final class LiveActivityTokenTests: XCTestCase {
    private func liveActivityTokens(_ harness: CoreHarness) throws -> [[String: HeraldValue]] {
        try harness.transport.batchBodies()
            .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap(\.objectValue)
            .filter { $0["type"] == "push_token" && $0["platform"] == "apns_live_activity" }
    }

    func testLiveActivityTokenWireFormat() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setLiveActivityToken(hex: "0a1b2c")
        await core.drain()
        await core.flushNow()
        let event = try XCTUnwrap(liveActivityTokens(harness).first)
        XCTAssertEqual(
            Set(event.keys), ["id", "type", "timestamp", "sessionId", "platform", "token", "environment", "bundleId"])
        XCTAssertEqual(event["type"], "push_token")
        XCTAssertEqual(event["platform"], "apns_live_activity")
        XCTAssertEqual(event["token"], "0a1b2c")
        XCTAssertEqual(event["environment"], "production")
        XCTAssertEqual(event["bundleId"], "com.lumen.app")
    }

    func testNotSentWhileDisabledAndResentOnReEnable() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setEnabled(false)
        await core.setLiveActivityToken(hex: "abcd")
        await core.drain()
        await core.flushNow()
        XCTAssertTrue(try liveActivityTokens(harness).isEmpty, "never sent while disabled")

        await core.setEnabled(true)
        await core.drain()
        await core.flushNow()
        XCTAssertEqual(try liveActivityTokens(harness).map { $0["token"] }, ["abcd"], "stored token re-sent on enable")
    }

    func testResentForANewUser() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setLiveActivityToken(hex: "abcd")
        await core.identify(userId: "u1", traits: [:])
        await core.drain()
        await core.flushNow()
        XCTAssertEqual(try liveActivityTokens(harness).count, 2)
    }
}
