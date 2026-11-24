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
