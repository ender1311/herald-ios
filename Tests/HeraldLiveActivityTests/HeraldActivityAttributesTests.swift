import XCTest
@testable import HeraldLiveActivity

final class HeraldActivityAttributesTests: XCTestCase {
    /// ActivityKit decodes the server's content-state with a default JSONDecoder: endsAt stays Unix seconds.
    func testContentStateDecodesWithDefaultDecoder() throws {
        let json = #"{"title":"Live now","body":"Join us","progress":0.5,"endsAt":1763200000}"#
        let state = try JSONDecoder().decode(HeraldActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertEqual(state, .init(title: "Live now", body: "Join us", progress: 0.5, endsAt: 1_763_200_000))
    }

    func testContentStateOptionalFieldsMayBeMissing() throws {
        let state = try JSONDecoder().decode(
            HeraldActivityAttributes.ContentState.self, from: Data(#"{"title":"t","body":"b"}"#.utf8))
        XCTAssertNil(state.progress)
        XCTAssertNil(state.endsAt)
    }

    func testAttributesDecode() throws {
        let attributes = try JSONDecoder().decode(
            HeraldActivityAttributes.self, from: Data(#"{"campaignId":"c1","deeplink":"app://x"}"#.utf8))
        XCTAssertEqual(attributes, .init(campaignId: "c1", deeplink: "app://x"))
        let bare = try JSONDecoder().decode(HeraldActivityAttributes.self, from: Data(#"{"campaignId":"c1"}"#.utf8))
        XCTAssertNil(bare.deeplink)
    }
}
