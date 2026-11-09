import os
import XCTest
@testable import HeraldSDK

@MainActor
private final class FakePresenter: InAppMessagePresenter {
    var accepts: Bool
    var presented: [String] = []

    init(accepts: Bool) { self.accepts = accepts }

    func present(_ message: InAppMessage, onClose: @escaping @MainActor @Sendable () -> Void) -> Bool {
        presented.append(message.id)
        return accepts
    }
}

@MainActor
final class PresenterContractTests: XCTestCase {
    private let message = InAppMessage(id: "m1", type: .modal)

    func testPresenterThatShowsReportsDisplay() {
        let bridge = MainActorBridge(store: ContentCardStore())
        let presenter = FakePresenter(accepts: true)
        bridge.presenter = presenter
        XCTAssertEqual(bridge.offer(message, onClose: {}), .display)
        XCTAssertEqual(presenter.presented, ["m1"])
    }

    // A presenter with no active scene returns false: the core must treat it like "no presenter" (stays pending).
    func testPresenterThatCannotShowLeavesMessagePending() {
        let bridge = MainActorBridge(store: ContentCardStore())
        bridge.presenter = FakePresenter(accepts: false)
        XCTAssertNil(bridge.offer(message, onClose: {}))
    }

}

final class DebugHookTests: XCTestCase {
    func testDebugLoadThenShowBypassesTrigger() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        await core.appDidBecomeActive()
        await core.drain()
        await core.debugApply(try MessagesPayload.decode(fixtureData("messages")))
        await core.drain()
        XCTAssertEqual(harness.output.lastCards?.map(\.id), ["msg_1", "msg_3", "msg_4"])

        await core.debugShowInAppMessage("msg_6")  // push_open trigger, never fired
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_6"])

        await core.debugShowInAppMessage("msg_2")  // msg_6 still on screen
        await core.debugShowInAppMessage("nope")
        await core.drain()
        XCTAssertEqual(harness.output.offered.map(\.id), ["msg_6"])
    }
}

final class CallBufferTests: XCTestCase {
    // Parity ruling: 1,000 calls are buffered before configure; newer ones are dropped.
    func testPreConfigureBufferKeepsOldestThousand() async throws {
        let herald = Herald()
        let ran = OSAllocatedUnfairLock(initialState: [Int]())
        for n in 0..<(Herald.maxBufferedCalls + 5) {
            herald.send { _ in ran.withLock { $0.append(n) } }
        }
        let directory = tempDirectory()
        var configuration = HeraldConfiguration(appKey: "pk_live", endpoint: URL(string: "https://h.example.com")!)
        configuration.flushInterval = 3600
        herald.start(configuration, storage: { Storage(directory: directory) }, transport: FakeTransport(), deviceInfo: FixtureDeviceInfo())
        for _ in 0..<300 where ran.withLock({ $0.count }) < Herald.maxBufferedCalls {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let order = ran.withLock { $0 }
        XCTAssertEqual(order, Array(0..<Herald.maxBufferedCalls))
    }
}
