import XCTest
@testable import HeraldSDK

final class HeraldFacadeTests: XCTestCase {
    /// Public calls made before and after configure reach the core in order and are sent.
    @MainActor
    func testCallsFlowThroughToTheNetworkInOrder() async throws {
        let transport = FakeTransport()
        // One sync at session start, one when the anonymous user is identified.
        transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))
        transport.enqueueMessages(FakeResponse(status: 200, body: try fixtureData("messages")))
        let directory = tempDirectory()
        let herald = Herald()
        herald.track("before_configure")

        var configuration = HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushInterval = 3600
        herald.start(configuration, storage: { Storage(directory: directory) }, transport: transport, deviceInfo: FixtureDeviceInfo())
        herald.identify(userId: "u_1", traits: ["plan": "free"])
        herald.track("workout_completed", properties: ["minutes": 5])
        herald.setEmail("maya@example.com")
        herald.flush()

        for _ in 0..<200 where transport.batchRequests.count < 2 || herald.contentCards.cards.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let bodies = try transport.batchBodies().compactMap(\.objectValue)
        XCTAssertEqual(bodies.map { $0["userId"] ?? .null }, [.null, "u_1"], "pre-login events go out as an anonymous batch")
        let types = bodies.map { $0["events"]?.arrayValue?.compactMap { $0.objectValue?["type"]?.stringValue } ?? [] }
        XCTAssertEqual(types, [["session_start", "track"], ["identify", "track", "attributes"]])
        XCTAssertEqual(herald.contentCards.cards.map(\.id), ["msg_1", "msg_3", "msg_4"])

        var updates = herald.contentCards.updates.makeAsyncIterator()
        let first = await updates.next()
        XCTAssertEqual(first?.count, 3, "a new stream yields the current cards immediately")
    }
}
