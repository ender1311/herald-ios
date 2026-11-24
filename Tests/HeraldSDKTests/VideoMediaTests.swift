import Foundation
import XCTest
@testable import HeraldSDK

/// Media library (spec 5.4/5.5): in-app and card video keys, and the video interaction events.
final class VideoMediaTests: XCTestCase {
    private let credit = #"{"name":"Ana","profileUrl":"https://unsplash.com/@ana","sourceUrl":"https://unsplash.com/photos/x"}"#

    func testDecodesVideoKeys() throws {
        let json = """
        {"data":{"contentCards":[{"id":"c1","type":"captioned_image","imageUrl":"https://p.test/poster.jpg",
        "videoUrl":"https://v.test/clip.mp4","videoPosterUrl":"https://p.test/poster.jpg","videoAutoplay":true,"credit":\(credit)}],
        "inAppMessages":[{"id":"m1","type":"modal","trigger":{"type":"session_start"},
        "content":{"imageUrl":"https://p.test/poster.jpg","videoUrl":"https://v.test/clip.mp4","videoPosterUrl":"https://p.test/poster.jpg","credit":\(credit)}}]}}
        """
        let payload = try MessagesPayload.decode(Data(json.utf8))
        let card = try XCTUnwrap(payload.contentCards.first)
        XCTAssertEqual(card.videoUrl, URL(string: "https://v.test/clip.mp4"))
        XCTAssertEqual(card.videoPosterUrl, URL(string: "https://p.test/poster.jpg"))
        XCTAssertTrue(card.videoAutoplay)
        XCTAssertEqual(card.credit, MediaCredit(
            name: "Ana", profileUrl: URL(string: "https://unsplash.com/@ana"), sourceUrl: URL(string: "https://unsplash.com/photos/x")
        ))
        let content = try XCTUnwrap(payload.inAppMessages.first).content
        XCTAssertEqual(content.videoUrl, URL(string: "https://v.test/clip.mp4"))
        XCTAssertEqual(content.videoPosterUrl, URL(string: "https://p.test/poster.jpg"))
        XCTAssertEqual(content.credit?.name, "Ana")
    }

    func testOldPayloadsDecodeWithoutVideo() throws {
        let payload = try MessagesPayload.decode(fixtureData("messages"))
        XCTAssertEqual(payload.contentCards.map(\.id), ["msg_1", "msg_3", "msg_4"])
        for card in payload.contentCards {
            XCTAssertNil(card.videoUrl)
            XCTAssertNil(card.videoPosterUrl)
            XCTAssertFalse(card.videoAutoplay)
            XCTAssertNil(card.credit)
        }
        for message in payload.inAppMessages {
            XCTAssertNil(message.content.videoUrl)
            XCTAssertNil(message.content.videoPosterUrl)
            XCTAssertNil(message.content.credit)
        }
    }

    func testMalformedVideoKeysAreIgnored() throws {
        let json = #"""
        {"data":{"contentCards":[{"id":"c1","type":"classic","videoUrl":42,"videoAutoplay":"yes","credit":{"profileUrl":"https://x"}}]}}
        """#
        let card = try XCTUnwrap(MessagesPayload.decode(Data(json.utf8)).contentCards.first)
        XCTAssertNil(card.videoUrl)
        XCTAssertFalse(card.videoAutoplay)
        XCTAssertNil(card.credit, "a credit needs a name")
    }

    func testVideoInteractionsAreSent() async throws {
        let harness = CoreHarness()
        let core = harness.makeCore()
        let card = ContentCard(id: "c1", type: .captionedImage, decisionId: "dec_1")
        let message = InAppMessage(id: "m1", type: .modal, decisionId: "dec_2")
        await core.logVideo(messageId: card.id, kind: "content_card", decisionId: card.decisionId, completed: false)
        await core.logVideo(messageId: card.id, kind: "content_card", decisionId: card.decisionId, completed: true)
        await core.logVideo(messageId: message.id, kind: "in_app", decisionId: message.decisionId, completed: false)
        await core.logVideo(messageId: message.id, kind: "in_app", decisionId: message.decisionId, completed: true)
        await core.flushNow()
        let events = try harness.transport.batchBodies().flatMap { $0.objectValue?["events"]?.arrayValue ?? [] }
        let sent = events.compactMap(\.objectValue).filter { $0["type"] == "interaction" }
            .map { "\($0["kind"]?.stringValue ?? "") \($0["action"]?.stringValue ?? "") \($0["messageId"]?.stringValue ?? "") \($0["decisionId"]?.stringValue ?? "")" }
        XCTAssertEqual(sent, [
            "content_card video_play c1 dec_1", "content_card video_complete c1 dec_1",
            "in_app video_play m1 dec_2", "in_app video_complete m1 dec_2",
        ])
    }
}
