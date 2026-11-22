import XCTest
@testable import HeraldSDK

/// The person's User ID from the batch response (`data.heraldId`, batch-response.json).
final class HeraldIdTests: XCTestCase {
    func testNilBeforeTheFirstSyncThenParsedAndCachedAcrossLaunches() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u_123", traits: [:])
        XCTAssertNil(core.heraldIdMirror.withLock { $0 })

        harness.transport.enqueueBatch(FakeResponse(status: 200, body: try fixtureData("batch-response")))
        await core.flushNow()
        XCTAssertEqual(core.heraldIdMirror.withLock { $0 }, "7K3M-9QXA")
        let persisted = await core.state.heraldId
        XCTAssertEqual(persisted, "7K3M-9QXA")

        let relaunched = harness.makeCore()
        XCTAssertEqual(relaunched.heraldIdMirror.withLock { $0 }, "7K3M-9QXA")
    }

    func testClearedOnResetAndIgnoredForAnonymousBatches() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.identify(userId: "u_123", traits: [:])
        harness.transport.enqueueBatch(FakeResponse(status: 200, body: try fixtureData("batch-response")))
        await core.flushNow()

        await core.reset()
        XCTAssertNil(core.heraldIdMirror.withLock { $0 })
        // The anonymous batch after reset (an older server could still answer with an id) doesn't set one.
        harness.transport.enqueueBatch(FakeResponse(status: 200, body: try fixtureData("batch-response")))
        await core.flushNow()
        XCTAssertNil(core.heraldIdMirror.withLock { $0 })
    }
}
