import XCTest
@testable import HeraldUI

final class VideoAutoplayTests: XCTestCase {
    func testAutoplaysOnlyWhenHalfVisibleEnabledAndMotionAllowed() {
        XCTAssertTrue(VideoAutoplay.shouldPlay(visibleFraction: 0.5, autoplay: true, reduceMotion: false))
        XCTAssertTrue(VideoAutoplay.shouldPlay(visibleFraction: 1, autoplay: true, reduceMotion: false))
        XCTAssertFalse(VideoAutoplay.shouldPlay(visibleFraction: 0.49, autoplay: true, reduceMotion: false), "under half visible: paused")
        XCTAssertFalse(VideoAutoplay.shouldPlay(visibleFraction: 0, autoplay: true, reduceMotion: false), "off screen: paused")
        XCTAssertFalse(VideoAutoplay.shouldPlay(visibleFraction: 1, autoplay: false, reduceMotion: false), "videoAutoplay off (the default)")
        XCTAssertFalse(VideoAutoplay.shouldPlay(visibleFraction: 1, autoplay: true, reduceMotion: true), "Reduce Motion disables autoplay")
    }

    func testPlayButtonLabel() {
        XCTAssertEqual(VideoAutoplay.playButtonLabel, "Play video")
    }
}

final class VideoPlayEventsTests: XCTestCase {
    func testOnePlayAndOneCompletePerPlay() {
        var events = VideoPlayEvents()
        XCTAssertTrue(events.started(), "first start: video_play")
        XCTAssertFalse(events.started(), "resume or status change during the same play")
        XCTAssertFalse(events.ended(ownItem: false), "another view's item ending")
        XCTAssertTrue(events.ended(ownItem: true), "own item ends: video_complete")
        XCTAssertFalse(events.ended(ownItem: true), "a second end notification (or the next loop) is not another complete")
        XCTAssertTrue(events.started(), "replay after the end: a new play")
        XCTAssertTrue(events.ended(ownItem: true))
    }

    func testEndBeforeStartIsIgnored() {
        var events = VideoPlayEvents()
        XCTAssertFalse(events.ended(ownItem: true))
    }
}
