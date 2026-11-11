import XCTest
@testable import HeraldSDK

final class SyncPushTests: XCTestCase {
    private func syncFromPush(_ core: HeraldCore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { await core.syncFromPush { done.resume() } }
        }
        await core.drain()
    }

    func testSyncPushRefreshesWithETagAndDebounces() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        harness.transport.enqueueMessages(FakeResponse(status: 200, headers: ["ETag": "\"v1\""], body: try fixtureData("messages")))
        await syncFromPush(core)
        XCTAssertEqual(harness.transport.messageRequests.count, 1)
        let cards = await core.visibleCards()
        XCTAssertEqual(cards.map(\.id), ["msg_1", "msg_3", "msg_4"])

        harness.clock.advance(29)
        await syncFromPush(core)
        XCTAssertEqual(harness.transport.messageRequests.count, 1, "a second sync push within 30 s is skipped")

        harness.clock.advance(2)
        harness.transport.enqueueMessages(FakeResponse(status: 304))
        await syncFromPush(core)
        XCTAssertEqual(harness.transport.messageRequests.count, 2)
        XCTAssertEqual(harness.transport.messageRequests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertTrue(harness.transport.batchRequests.isEmpty, "a sync push logs nothing")
    }

    func testSyncPushDoesNothingWhileDisabled() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setEnabled(false)
        await core.drain()
        let before = harness.transport.requests.count
        await syncFromPush(core)
        XCTAssertEqual(harness.transport.requests.count, before)
    }

    func testSyncPushIsNotAnOpenablePush() {
        XCTAssertNil(HeraldPushPayload(userInfo: ["herald_sync": "1", "herald_message_id": "m1"]))
        XCTAssertNotNil(HeraldPushPayload(userInfo: ["herald_message_id": "m1"]))
    }

    @MainActor
    func testHandleRemoteNotification() async throws {
        let transport = FakeTransport()
        transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))  // session start
        let directory = tempDirectory()
        let herald = Herald()
        var configuration = HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushInterval = 3600
        herald.start(configuration, storage: { Storage(directory: directory) }, transport: transport, deviceInfo: FixtureDeviceInfo())

        let other = await herald.handleRemoteNotification(["aps": ["alert": "hi"], "herald_message_id": "m1"])
        XCTAssertFalse(other)
        let before = transport.messageRequests.count
        transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))
        let synced = await herald.handleRemoteNotification(["aps": ["content-available": 1], "herald_sync": "1"])
        XCTAssertTrue(synced)
        XCTAssertGreaterThan(transport.messageRequests.count, before, "the refresh finished before it returned")
    }
}
