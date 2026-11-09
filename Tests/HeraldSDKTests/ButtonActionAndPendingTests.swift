import XCTest
@testable import HeraldSDK

final class ButtonActionAndPendingTests: XCTestCase {
    private func button(_ action: String) throws -> InAppMessage.Button {
        try JSONDecoder().decode(InAppMessage.Button.self, from: Data(#"{"id":"b","text":"T","action":\#(action)}"#.utf8))
    }

    // Docs review bug: `url` actions decoded as close.
    func testButtonActionDecoding() throws {
        XCTAssertEqual(try button(#"{"type":"url","value":"https://lumen.example/plans"}"#).action, .url(URL(string: "https://lumen.example/plans")!))
        XCTAssertEqual(try button(#"{"type":"deeplink","value":"lumen://plus"}"#).action, .deeplink(URL(string: "lumen://plus")!))
        XCTAssertEqual(try button(#"{"type":"close","value":null}"#).action, .close)
        XCTAssertEqual(try button(#"{"type":"teleport","value":"lumen://x"}"#).action, .close, "unknown type")
        XCTAssertEqual(try button(#"{"type":"url","value":null}"#).action, .close, "url without a value")
        XCTAssertEqual(try button("null").action, .close)
        XCTAssertEqual(InAppMessage.ButtonAction.url(URL(string: "https://a.test")!).url, URL(string: "https://a.test"))
        XCTAssertNil(InAppMessage.ButtonAction.close.url)
    }

    func testShowNextPicksHighestPriorityThenOldestPending() {
        var engine = InAppEngine(minimumInterval: 30)
        engine.messages = [
            InAppMessage(id: "a", type: .modal, priority: 1),
            InAppMessage(id: "b", type: .modal, priority: 5),
            InAppMessage(id: "c", type: .modal, priority: 5),
            InAppMessage(id: "d", type: .modal, priority: 9, expiresAt: t0),
        ]
        // Pending oldest first: c was pending before b; d is expired.
        XCTAssertEqual(engine.nextPending(["a", "c", "b", "d"], now: t0)?.id, "c")
        XCTAssertEqual(engine.nextPending(["b", "a", "c"], now: t0)?.id, "b")
        XCTAssertEqual(engine.nextPending(["a"], now: t0)?.id, "a")
        XCTAssertNil(engine.nextPending(["d"], now: t0))
    }
}
