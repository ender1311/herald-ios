import os
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

    /// I6: a refresh that never finishes must not hold the completion handler past the deadline.
    @MainActor
    func testHandleRemoteNotificationReturnsByTheDeadline() async throws {
        let transport = StallingTransport()
        let herald = Herald()
        var configuration = HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushInterval = 3600
        let directory = tempDirectory()
        herald.start(configuration, storage: { Storage(directory: directory) }, transport: transport, deviceInfo: FixtureDeviceInfo())
        // Let the session-start sync finish, so the push's refresh is the one that stalls.
        for _ in 0..<200 where transport.messageRequests < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)

        let started = Date()
        let synced = await herald.handleRemoteNotification(["herald_sync": "1"], deadline: 0.3)
        XCTAssertTrue(synced)
        XCTAssertEqual(transport.messageRequests, 2, "the push's refresh started and is still stalled")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "returned at the deadline, not when the refresh ends")
    }

    @MainActor
    func testHandleRemoteNotificationBeforeConfigureReturnsAtOnce() async {
        let herald = Herald()
        let synced = await herald.handleRemoteNotification(["herald_sync": "1"], deadline: 60)
        XCTAssertTrue(synced, "still a Herald sync payload")
        let other = await herald.handleRemoteNotification(["aps": ["alert": "hi"]], deadline: 60)
        XCTAssertFalse(other)
    }
}

/// Fix round 1: `Herald.shared.isEnabled` follows setEnabled / wipeData at once and the loaded state.
final class IsEnabledTests: XCTestCase {
    func testIsEnabledFollowsCallsAndLoadedState() async throws {
        let directory = tempDirectory()
        let core = CoreHarness(directory: directory).makeCore()
        await core.setEnabled(false)
        await core.drain()

        let herald = Herald()
        herald.start(
            HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!),
            storage: { Storage(directory: directory) }, transport: FakeTransport(), deviceInfo: FixtureDeviceInfo()
        )
        for _ in 0..<200 where herald.isEnabled { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(herald.isEnabled, "the opt-out persisted on disk is loaded")
        herald.setEnabled(true)
        XCTAssertTrue(herald.isEnabled, "reflects the call at once")
        herald.wipeData()
        XCTAssertFalse(herald.isEnabled)
    }
}

/// Answers the first message sync; every later one never finishes (until its task is cancelled).
final class StallingTransport: HeraldTransport {
    private let syncs = OSAllocatedUnfairLock(initialState: 0)
    var messageRequests: Int { syncs.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path.hasSuffix("/sdk/messages") == true {
            let n = syncs.withLock { count -> Int in
                count += 1
                return count
            }
            while n > 1 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        let body = Data(#"{"data":{"syncedAt":null,"contentCards":[],"inAppMessages":[]}}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
