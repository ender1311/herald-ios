import XCTest
@testable import HeraldSDK

final class ExternalPushTests: XCTestCase {
    func testHeraldSyncSilentAndLocalNotificationsAreNotCaptured() {
        let alert: [String: Any] = ["alert": ["title": "Order", "body": "Shipped"]]
        XCTAssertNil(ExternalPush.capture(userInfo: ["aps": alert, "nexus_decision_id": "d1"], requestIdentifier: "r1"))
        XCTAssertNil(ExternalPush.capture(userInfo: ["aps": alert, "herald_message_id": "m1"], requestIdentifier: "r1"))
        XCTAssertNil(ExternalPush.capture(userInfo: ["aps": ["content-available": 1], "herald_sync": "1"], requestIdentifier: "r1"))
        XCTAssertNil(ExternalPush.capture(userInfo: ["aps": ["content-available": 1]], requestIdentifier: "r1"), "silent")
        XCTAssertNil(ExternalPush.capture(userInfo: ["orderId": "42"], requestIdentifier: "r1"), "local notification")
    }

    func testIdsAndCategory() throws {
        let alert: [String: Any] = ["alert": "Your code is 1234"]
        let own = try XCTUnwrap(ExternalPush.capture(
            userInfo: ["aps": alert, "herald_external_id": "order-42", "herald_category": "transactional"], requestIdentifier: "r1"))
        XCTAssertEqual(own.messageId, "order-42")
        XCTAssertEqual(own.category, .transactional)
        let fallback = try XCTUnwrap(ExternalPush.capture(userInfo: ["aps": alert, "herald_category": "promo"], requestIdentifier: "r1"))
        XCTAssertEqual(fallback.messageId, "r1", "the request id, so shown and tapped dedupe")
        XCTAssertEqual(fallback.category, .other, "an unknown category reads as other")
        let tooLong = try XCTUnwrap(ExternalPush.capture(
            userInfo: ["aps": alert, "herald_external_id": String(repeating: "x", count: 201)], requestIdentifier: "r1"))
        XCTAssertEqual(tooLong.messageId, "r1")
    }

    private func externalPushEvents(_ harness: CoreHarness) throws -> [[String: HeraldValue]] {
        try harness.transport.batchBodies()
            .flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
            .compactMap(\.objectValue)
            .filter { $0["type"] == "track" && $0["name"] == "$external_push" }
    }

    func testPublicMethodRecordsTheEvent() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.trackExternalPush(messageId: "order-42", category: .transactional, source: "orders", automatic: false)
        await core.trackExternalPush(messageId: nil, category: .other, source: nil, automatic: false)
        await core.trackExternalPush(messageId: String(repeating: "x", count: 201), category: .other, source: nil, automatic: false)
        await core.flushNow()
        let events = try externalPushEvents(harness)
        XCTAssertEqual(events.count, 2, "a too-long id is rejected")
        XCTAssertEqual(events[0]["properties"], .object(["category": "transactional", "message_id": "order-42", "source": "orders"]))
        XCTAssertEqual(events[1]["properties"], .object(["category": "other"]))
    }

    func testAutomaticCaptureFollowsTheFlag() async throws {
        let harness = CoreHarness()
        let off = harness.makeCore { $0.trackExternalPushes = false }
        await off.trackExternalPush(messageId: "r1", category: .other, source: nil, automatic: true)
        await off.trackExternalPush(messageId: "r2", category: .other, source: nil, automatic: false)
        await off.flushNow()
        XCTAssertEqual(try externalPushEvents(harness).map { $0["properties"]?.objectValue?["message_id"] }, ["r2"])
    }
}
