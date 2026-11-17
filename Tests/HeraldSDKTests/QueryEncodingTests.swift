import XCTest
@testable import HeraldSDK

// audit 2026-11-17: iOS message sync breaks for user IDs that contain `+`
final class QueryEncodingTests: XCTestCase {
    func testMessageSyncEscapesPlusInTheUserId() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u+1@x.com", traits: [:])
        await core.drain()
        let url = try XCTUnwrap(harness.transport.messageRequests.last?.url)
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("userId=u%2B1@x.com"), query)
        XCTAssertFalse(query.contains("+"), query)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "userId" }?.value, "u+1@x.com")
    }
}
