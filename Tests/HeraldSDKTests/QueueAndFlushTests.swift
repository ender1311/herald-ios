import XCTest
@testable import HeraldSDK

final class QueueAndFlushTests: XCTestCase {
    private func entry(_ n: Int, user: String? = nil) -> QueuedEvent {
        QueuedEvent(userId: user, event: ["id": .string("e\(n)"), "type": "track", "name": "x"])
    }

    func testQueueSurvivesReinitAndTornLine() throws {
        let url = tempDirectory().appendingPathComponent("events.jsonl")
        let queue = EventQueue(fileURL: url)
        (1...3).forEach { queue.append(entry($0)) }

        // Simulate a crash mid-append.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"userId":null,"event":{"id":"e4","ty"#.utf8))
        try handle.close()

        let reloaded = EventQueue(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.id), ["e1", "e2", "e3"])
        reloaded.append(entry(5))
        XCTAssertEqual(EventQueue(fileURL: url).entries.map(\.id), ["e1", "e2", "e3", "e5"])

        reloaded.remove(ids: ["e2"])
        XCTAssertEqual(EventQueue(fileURL: url).entries.map(\.id), ["e1", "e3", "e5"])
    }

    func testCoreQueueSurvivesRelaunch() async throws {
        let harness = CoreHarness()
        let first = harness.makeCore()
        await first.track("a", properties: [:])
        await first.track("b", properties: [:])
        await first.drain()

        let relaunched = harness.makeCore()
        let count = await relaunched.queuedCount
        XCTAssertEqual(count, 3, "session_start + 2 tracks")
        await relaunched.flushNow()
        let events = try XCTUnwrap(harness.transport.batchBodies().first?.objectValue?["events"]?.arrayValue)
        XCTAssertEqual(events.compactMap { $0.objectValue?["name"]?.stringValue }, ["a", "b"])
        let remaining = await relaunched.queuedCount
        XCTAssertEqual(remaining, 0)
    }

    func testUnencodableEventIsSkipped() {
        let queue = EventQueue(fileURL: tempDirectory().appendingPathComponent("events.jsonl"))
        queue.append(QueuedEvent(userId: nil, event: ["id": "x", "value": .number(.infinity)]))
        XCTAssertEqual(queue.count, 0)
    }

    func testCapDropsOldestAndCounts() {
        let queue = EventQueue(fileURL: tempDirectory().appendingPathComponent("events.jsonl"))
        var dropped = 0
        for n in 1...1005 { dropped += queue.append(entry(n)) }
        XCTAssertEqual(queue.count, 1000)
        XCTAssertEqual(dropped, 5)
        XCTAssertEqual(queue.entries.first?.id, "e6")
    }

    func testDroppedCountIsSentThenCleared() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        for n in 0..<1004 { await core.track("e\(n)", properties: [:]) }
        await core.drain()
        let dropped = await core.state.dropped
        XCTAssertEqual(dropped, 5, "1 session_start + 1004 tracks over a cap of 1000")

        await core.flushNow()
        let bodies = try harness.transport.batchBodies()
        XCTAssertEqual(bodies.count, 10)
        XCTAssertEqual(bodies.first?.objectValue?["dropped"], 5)
        XCTAssertEqual(bodies.last?.objectValue?["dropped"], 0)
        XCTAssertTrue(bodies.allSatisfy { ($0.objectValue?["events"]?.arrayValue?.count ?? 0) <= 100 })
        let after = await core.state.dropped
        XCTAssertEqual(after, 0)
    }

    func testBackoffSchedule() {
        let full = (1...10).map { Backoff.delay(attempt: $0, random: 1) }
        XCTAssertEqual(full, [1, 2, 4, 8, 16, 32, 64, 128, 256, 300])
        XCTAssertEqual(Backoff.delay(attempt: 3, random: 0), 2, "jitter keeps at least half the delay")
        XCTAssertEqual(Backoff.delay(attempt: 99, random: 1), 300)
    }

    func testServerErrorRetriesWithBackoffAndKeepsEvents() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("a", properties: [:])
        await core.drain()

        harness.transport.enqueueBatch(FakeResponse(status: 503))
        await core.flushNow()
        var next = await core.nextAttemptAt
        XCTAssertEqual(next, t0.addingTimeInterval(1))
        let v1 = await core.queuedCount
        XCTAssertEqual(v1, 2)

        await core.flushNow()  // still inside the backoff window: no request
        XCTAssertEqual(harness.transport.batchRequests.count, 1)

        harness.clock.advance(1)
        harness.transport.enqueueBatchError(URLError(.notConnectedToInternet))
        await core.flushNow()
        next = await core.nextAttemptAt
        XCTAssertEqual(next, t0.addingTimeInterval(1 + 2), "second failure doubles the delay")

        harness.clock.advance(2)
        await core.flushNow()
        let v2 = await core.queuedCount
        XCTAssertEqual(v2, 0)
        let v3 = await core.failureCount
        XCTAssertEqual(v3, 0)
        XCTAssertEqual(harness.transport.batchRequests.count, 3)
    }

    func testRetryAfterIsHonored() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("a", properties: [:])
        await core.drain()

        harness.transport.enqueueBatch(FakeResponse(status: 429, headers: ["Retry-After": "30"], body: try fixtureData("errors")))
        await core.flushNow()
        let v4 = await core.nextAttemptAt
        XCTAssertEqual(v4, t0.addingTimeInterval(30))

        harness.clock.advance(30)
        harness.transport.enqueueBatch(FakeResponse(status: 429, body: Data(#"{"error":"Rate limited","retryAfterSeconds":45}"#.utf8)))
        await core.flushNow()
        let v5 = await core.nextAttemptAt
        XCTAssertEqual(v5, t0.addingTimeInterval(75), "body retryAfterSeconds when the header is missing")
        let v6 = await core.queuedCount
        XCTAssertEqual(v6, 2)
    }

    func testRejectedBatchesAreDropped() async throws {
        for status in [400, 401, 413] {
            let harness = CoreHarness()
            let core = harness.makeCore()
            await core.track("a", properties: [:])
            await core.drain()
            harness.transport.enqueueBatch(FakeResponse(status: status, body: Data(#"{"error":"Invalid user token"}"#.utf8)))
            await core.flushNow()
            let v7 = await core.queuedCount
            XCTAssertEqual(v7, 0, "HTTP \(status) drops the batch")
            let v8 = await core.nextAttemptAt
            XCTAssertNil(v8, "HTTP \(status) does not back off")
            XCTAssertEqual(harness.transport.batchRequests.count, 1)
        }
    }

    func testBatchesNeverMixUsers() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.track("anon_before", properties: [:])
        await core.identify(userId: "u1", traits: [:])
        await core.setUserToken("tok1")
        await core.track("u1_event", properties: [:])
        await core.reset()
        await core.track("anon_after", properties: [:])
        await core.identify(userId: "u2", traits: [:])
        await core.drain()
        await core.flushNow()

        let requests = harness.transport.batchRequests
        let bodies = try harness.transport.batchBodies()
        XCTAssertEqual(bodies.map { $0.objectValue?["userId"] }, [.string("u1"), .string("u2")])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "x-herald-user-token") }, ["tok1", nil])
        let firstNames = bodies[0].objectValue?["events"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(firstNames, ["anon_before", "u1_event"], "anonymous events lead into the identify that follows")
        let pending = await core.state.pendingTokens
        XCTAssertTrue(pending.isEmpty, "previous user's token is forgotten once their events are sent")
    }
}
