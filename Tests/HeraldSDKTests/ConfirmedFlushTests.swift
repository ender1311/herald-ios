import XCTest
@testable import HeraldSDK

private func confirm(_ core: HeraldCore) async -> Bool {
    await withCheckedContinuation { continuation in
        Task { await core.confirmFlush { continuation.resume(returning: $0) } }
    }
}

final class ConfirmedFlushTests: XCTestCase {
    func testTrueOnceEverythingQueuedIsAccepted() async {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setAttributes(["email": .null])
        let delivered = await confirm(core)
        XCTAssertTrue(delivered)
        let left = await core.queuedCount
        XCTAssertEqual(left, 0)
        let empty = await confirm(core)
        XCTAssertTrue(empty, "nothing queued is trivially delivered")
    }

    func testFalseWhenTheTransportFailsOrTheServerDropsTheBatch() async {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("a", properties: [:])
        harness.transport.enqueueBatchError(URLError(.notConnectedToInternet))
        let offline = await confirm(core)
        XCTAssertFalse(offline)
        let inBackoff = await confirm(core)
        XCTAssertFalse(inBackoff, "inside the retry delay nothing is sent")
        XCTAssertEqual(harness.transport.batchRequests.count, 1)

        harness.clock.advance(60)
        harness.transport.enqueueBatch(FakeResponse(status: 400))
        let rejected = await confirm(core)
        XCTAssertFalse(rejected, "a dropped batch was never accepted")
    }

    func testEventsRecordedAfterTheCallDontCount() async {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("before", properties: [:])
        harness.transport.setBatchDelay(milliseconds: 100)
        harness.transport.enqueueBatch(FakeResponse(status: 200))
        harness.transport.enqueueBatch(FakeResponse(status: 503))
        let result = Task { await confirm(core) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        // A different user: its own batch, which fails.
        await core.identify(userId: "u_2", traits: [:])
        let delivered = await result.value
        XCTAssertTrue(delivered)
        let left = await core.queuedCount
        XCTAssertGreaterThan(left, 0, "the later event is still queued")
    }

    func testFalseWhenUnsentEventsAreEvictedDuringTheWait() async {
        let harness = CoreHarness()
        let core = harness.makeCore(queueCap: 3)
        await core.track("a", properties: [:])  // anonymous: its own batch
        await core.identify(userId: "u_1", traits: [:])  // u_1's batch, waits behind the first
        harness.transport.setBatchDelay(milliseconds: 100)
        let result = Task { await confirm(core) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for i in 0..<5 { await core.track("later_\(i)", properties: [:]) }  // evicts u_1's unsent identify
        let delivered = await result.value
        XCTAssertFalse(delivered)
    }

    func testFalseWhenWipedDuringTheWait() async {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("a", properties: [:])
        await core.identify(userId: "u_1", traits: [:])
        harness.transport.setBatchDelay(milliseconds: 100)
        let result = Task { await confirm(core) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await core.wipeData()
        let delivered = await result.value
        XCTAssertFalse(delivered)
    }

    func testFalseWhileDisabledEvenWithNothingQueued() async {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.setEnabled(false)
        await core.setAttributes(["email": .null])  // not recorded while disabled
        let delivered = await confirm(core)
        XCTAssertFalse(delivered)
    }

    @MainActor
    func testFacadeTimesOutWithoutBlockingOtherCalls() async throws {
        let transport = FakeTransport()
        transport.setBatchDelay(milliseconds: 1_000)
        let herald = Herald()
        var configuration = HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushInterval = 3600
        herald.start(configuration, storage: { Storage(directory: tempDirectory()) }, transport: transport, deviceInfo: FixtureDeviceInfo())
        herald.track("a")
        let started = Date()
        let delivered = await herald.flush(timeout: .milliseconds(100))
        XCTAssertFalse(delivered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        herald.setEnabled(false)
        XCTAssertFalse(herald.isEnabled)
    }
}
