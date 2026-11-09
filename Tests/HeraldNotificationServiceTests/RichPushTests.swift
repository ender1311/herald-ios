import UserNotifications
import XCTest
@testable import HeraldNotificationService

/// Serves canned responses so the download path runs without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var mimeType = "image/png"
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var delay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.mimeType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}

final class RichPushTests: XCTestCase {
    // 1x1 transparent PNG.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func content(_ userInfo: [AnyHashable: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Hi"
        content.userInfo = userInfo
        return content
    }

    override func setUp() {
        StubProtocol.status = 200
        StubProtocol.mimeType = "image/png"
        StubProtocol.body = png
        StubProtocol.delay = 0
    }

    func testImageURLRequiresHttps() {
        XCTAssertEqual(HeraldRichPush.imageURL(in: ["image_url": "https://x.test/a.png"]), URL(string: "https://x.test/a.png"))
        XCTAssertNil(HeraldRichPush.imageURL(in: ["image_url": "http://x.test/a.png"]))
        XCTAssertNil(HeraldRichPush.imageURL(in: ["image_url": "file:///etc/passwd"]))
        XCTAssertNil(HeraldRichPush.imageURL(in: [:]))
    }

    func testAttachesDownloadedImage() async {
        let result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/a"]), timeout: 5, session: session)
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.title, "Hi")
    }

    func testFallsBackOnHttpError() async {
        StubProtocol.status = 404
        let result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/a.png"]), timeout: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.title, "Hi")
    }

    func testFallsBackOnTimeout() async {
        StubProtocol.delay = 2
        let start = Date()
        let result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/a.png"]), timeout: 0.3, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testFallsBackOnUnknownType() async {
        StubProtocol.mimeType = "text/html"
        let result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/page"]), timeout: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
    }
}

final class ActionCategoryTests: XCTestCase {
    private func content(_ userInfo: [AnyHashable: Any], category: String = "") -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        content.categoryIdentifier = category
        return content
    }

    func testBuildsCategoryFromActions() throws {
        let json = #"[{"id":"a1","title":"Open","deeplink":"lumen://a"},{"id":"a2","title":"Later"},{"id":""},{"id":"a3","title":"C"},{"id":"a4","title":"D"}]"#
        let category = try XCTUnwrap(HeraldRichPush.actionCategory(for: content(["herald_actions": json])))
        XCTAssertEqual(category.actions.map(\.identifier), ["a1", "a2", "a3"])
        XCTAssertEqual(category.actions.map(\.title), ["Open", "Later", "C"])
        // Same buttons, same category id.
        XCTAssertEqual(HeraldRichPush.actionCategory(for: content(["herald_actions": json]))?.identifier, category.identifier)
    }

    func testNoCategoryWithoutActionsOrWhenApsCategorySet() {
        XCTAssertNil(HeraldRichPush.actionCategory(for: content([:])))
        XCTAssertNil(HeraldRichPush.actionCategory(for: content(["herald_actions": "nope"])))
        XCTAssertNil(HeraldRichPush.actionCategory(for: content(["herald_actions": [["id": "x", "title": "X"]]], category: "app")))
        XCTAssertEqual(HeraldRichPush.actionCategory(for: content(["herald_actions": [["id": "x", "title": "X"]]]))?.actions.count, 1)
    }
}
