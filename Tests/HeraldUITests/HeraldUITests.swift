import HeraldSDK
import SwiftUI
import XCTest
@testable import HeraldUI

final class HeraldUITests: XCTestCase {
    private func card(_ id: String, pinned: Bool = false, age: TimeInterval) -> ContentCard {
        ContentCard(id: id, type: .classic, pinned: pinned, createdAt: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    func testFeedOrdersPinnedFirstThenNewest() {
        let cards = [card("old", age: 300), card("pinnedOld", pinned: true, age: 900), card("new", age: 10), card("pinnedNew", pinned: true, age: 5)]
        let ids = ContentCardFeedDefaults.feedCards(cards, filter: { _ in true }, order: ContentCardFeedDefaults.order).map(\.id)
        XCTAssertEqual(ids, ["pinnedNew", "pinnedOld", "new", "old"])
    }

    func testFeedKeepsServerOrderForTiesAndAppliesFilter() {
        let cards = [card("a", age: 0), card("b", age: 0), card("c", age: 0)]
        let ids = ContentCardFeedDefaults.feedCards(cards, filter: { $0.id != "b" }, order: ContentCardFeedDefaults.order).map(\.id)
        XCTAssertEqual(ids, ["a", "c"])
    }

    func testImpressionNeedsHalfVisible() {
        XCTAssertTrue(ContentCardFeedDefaults.isImpression(visibleHeight: 50, fullHeight: 100))
        XCTAssertFalse(ContentCardFeedDefaults.isImpression(visibleHeight: 49, fullHeight: 100))
        XCTAssertFalse(ContentCardFeedDefaults.isImpression(visibleHeight: 0, fullHeight: 0))
    }

    func testImageDescriptionUsesTitleThenAlt() {
        XCTAssertEqual(ContentCardFeedDefaults.imageDescription(ContentCard(id: "1", type: .imageOnly, title: "T", extras: ["alt": "A"])), "T")
        XCTAssertEqual(ContentCardFeedDefaults.imageDescription(ContentCard(id: "1", type: .imageOnly, extras: ["alt": "A"])), "A")
        XCTAssertNil(ContentCardFeedDefaults.imageDescription(ContentCard(id: "1", type: .imageOnly)))
    }

    func testHexColors() {
        XCTAssertNotNil(Color(heraldHex: "#101828"))
        XCTAssertNotNil(Color(heraldHex: " #80FFFFFF "))
        XCTAssertNil(Color(heraldHex: "101828"))
        XCTAssertNil(Color(heraldHex: "#12345"))
        XCTAssertNil(Color(heraldHex: "#GGGGGG"))
        XCTAssertNil(Color(heraldHex: nil))
    }

    func testMessageStyleOverridesThemeAndNilFallsBack() {
        let theme = HeraldTheme(cornerRadius: 8)
        let styled = MessageColors(
            style: InAppMessage.Style(backgroundColor: "#101828", textColor: "#FFFFFF", cornerRadius: 20), theme: theme, colorScheme: .light
        )
        XCTAssertEqual(styled.background, Color(heraldHex: "#101828"))
        XCTAssertEqual(styled.text, Color(heraldHex: "#FFFFFF"))
        XCTAssertEqual(styled.button, HeraldColors.light.accent)
        XCTAssertEqual(styled.cornerRadius, 20)

        let plain = MessageColors(style: InAppMessage.Style(backgroundColor: "nope"), theme: theme, colorScheme: .dark)
        XCTAssertEqual(plain.background, HeraldColors.dark.surface)
        XCTAssertEqual(plain.cornerRadius, 8)
    }

    func testDarkModeOverride() {
        XCTAssertEqual(HeraldTheme(darkMode: true).colors(for: .light), .dark)
        XCTAssertEqual(HeraldTheme(darkMode: false).colors(for: .dark), .light)
        XCTAssertEqual(HeraldTheme().colors(for: .dark), .dark)
    }

    /// I4: a style background (or button) color without its text color gets black or white by contrast.
    func testPartialStyleOverridesPickReadableText() {
        let theme = HeraldTheme()
        for scheme in [ColorScheme.light, .dark] {
            let onWhite = MessageColors(style: .init(backgroundColor: "#FFFFFF", buttonColor: "#FFEB3B"), theme: theme, colorScheme: scheme)
            XCTAssertEqual(onWhite.text, .black, "\(scheme)")
            XCTAssertEqual(onWhite.buttonText, .black, "\(scheme)")
            let onDark = MessageColors(style: .init(backgroundColor: "#101828", buttonColor: "#1A237E"), theme: theme, colorScheme: scheme)
            XCTAssertEqual(onDark.text, .white, "\(scheme)")
            XCTAssertEqual(onDark.buttonText, .white, "\(scheme)")
            let explicit = MessageColors(style: .init(backgroundColor: "#FFFFFF", textColor: "#FF0000"), theme: theme, colorScheme: scheme)
            XCTAssertEqual(explicit.text, Color(heraldHex: "#FF0000"), "an explicit text color wins")
            let unset = MessageColors(style: .init(), theme: theme, colorScheme: scheme)
            XCTAssertEqual(unset.text, theme.colors(for: scheme).onSurface, "no style: the theme's colors")
            XCTAssertEqual(unset.buttonText, theme.colors(for: scheme).onAccent)
        }
    }
}
