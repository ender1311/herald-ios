import UniformTypeIdentifiers
import UserNotifications
import XCTest
@testable import HeraldNotificationService

/// Serves canned responses so the download path runs without a network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var mimeType = "image/png"
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var delay: TimeInterval = 0
    /// Per-URL overrides of the defaults above, for payloads with both a video and an image.
    struct Route {
        var status = 200
        var mimeType = "video/mp4"
        var body = Data()
        var delay: TimeInterval = 0
        var headers: [String: String] = [:]
    }
    nonisolated(unsafe) static var routes: [String: Route] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = Self.routes[request.url!.absoluteString]
            ?? Route(status: Self.status, mimeType: Self.mimeType, body: Self.body, delay: Self.delay)
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: route.status, httpVersion: nil,
                headerFields: ["Content-Type": route.mimeType].merging(route.headers) { $1 }
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if route.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + route.delay, execute: respond)
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
        StubProtocol.routes = [:]
    }

    func testImageURLRequiresHttps() {
        XCTAssertEqual(HeraldRichPush.imageURL(in: ["image_url": "https://x.test/a.png"]), URL(string: "https://x.test/a.png"))
        XCTAssertNil(HeraldRichPush.imageURL(in: ["image_url": "http://x.test/a.png"]))
        XCTAssertNil(HeraldRichPush.imageURL(in: ["image_url": "file:///etc/passwd"]))
        XCTAssertNil(HeraldRichPush.imageURL(in: [:]))
        XCTAssertEqual(HeraldRichPush.imageURL(in: ["image": "https://x.test/b.png"]), URL(string: "https://x.test/b.png"))
        XCTAssertEqual(HeraldRichPush.imageURL(in: ["image_url": "https://x.test/a.png", "image": "https://x.test/b.png"]), URL(string: "https://x.test/a.png"))
        XCTAssertEqual(HeraldRichPush.imageURL(in: ["image_url": "http://x.test/a.png", "image": "https://x.test/b.png"]), URL(string: "https://x.test/b.png"))
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

    func testFallsBackOnTooLargeAndWebp() async {
        StubProtocol.body = Data(count: HeraldRichPush.maxBytes + 1)
        var result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/a.png"]), timeout: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
        StubProtocol.body = png
        StubProtocol.mimeType = "image/webp"
        result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/a.webp"]), timeout: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty, "UNNotificationAttachment does not take webp")
    }

    func testFallsBackOnUnknownType() async {
        StubProtocol.mimeType = "text/html"
        let result = await HeraldRichPush.attachImage(to: content(["image_url": "https://x.test/page"]), timeout: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    // MARK: - Video (Review Focus 2: a video that can't download never costs the push its poster or its text)

    private let videoURL = "https://videos.test/clip.mp4"
    private let posterURL = "https://images.test/poster.png"
    private var mp4: Data { Data(base64Encoded: tinyMP4Base64)! }

    private func videoPush() -> UNNotificationContent {
        content(["video_url": videoURL, "image_url": posterURL])
    }

    func testVideoURLRequiresHttps() {
        XCTAssertEqual(HeraldRichPush.videoURL(in: ["video_url": "https://v.test/a.mp4"]), URL(string: "https://v.test/a.mp4"))
        XCTAssertNil(HeraldRichPush.videoURL(in: ["video_url": "http://v.test/a.mp4"]))
        XCTAssertNil(HeraldRichPush.videoURL(in: ["image_url": "https://v.test/a.mp4"]))
    }

    func testPrefersVideoUnderTheCap() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/mp4", body: mp4)
        let result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-video"])
        XCTAssertEqual(result.attachments.first?.type, UTType.mpeg4Movie.identifier)
        XCTAssertEqual(result.title, "Hi")
    }

    func testQuickTimeVideoGetsTheMovieHint() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/quicktime", body: mp4)
        let result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-video"])
        XCTAssertEqual(result.attachments.first?.type, UTType.quickTimeMovie.identifier)
    }

    func testVideo404FallsBackToPoster() async {
        StubProtocol.routes[videoURL] = .init(status: 404, mimeType: "text/html")
        let result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"])
    }

    func testTooBigVideoFallsBackToPoster() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/mp4", body: Data(count: HeraldRichPush.maxVideoBytes + 1))
        var result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"], "actual bytes over the cap")
        StubProtocol.routes[videoURL] = .init(
            mimeType: "video/mp4", body: mp4, headers: ["Content-Length": String(HeraldRichPush.maxVideoBytes + 1)]
        )
        result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"], "Content-Length over the cap")
    }

    func testWrongMimeVideoFallsBackToPoster() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/webm", body: mp4)
        var result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"])
        StubProtocol.routes[videoURL] = .init(mimeType: "application/octet-stream", body: mp4)
        result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"], "no guessing from the .mp4 extension")
    }

    func testSlowVideoLeavesTimeForThePoster() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/mp4", body: mp4, delay: 3)
        let start = Date()
        let result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 1, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "within the budget")
    }

    func testVideoAndPosterBothFailingStillShowsText() async {
        StubProtocol.routes[videoURL] = .init(status: 404, mimeType: "text/html")
        StubProtocol.routes[posterURL] = .init(status: 500, mimeType: "text/html")
        let result = await HeraldRichPush.attachMedia(to: videoPush(), budget: 5, session: session)
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.title, "Hi")
    }

    func testNoVideoAttachesImageAsBefore() async {
        let result = await HeraldRichPush.attachMedia(to: content(["image_url": posterURL]), budget: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-image"])
    }

    func testPrepareUsesTheVideo() async {
        StubProtocol.routes[videoURL] = .init(mimeType: "video/mp4", body: mp4)
        let result = await HeraldRichPush.prepare(videoPush(), timeout: 5, session: session)
        XCTAssertEqual(result.attachments.map(\.identifier), ["herald-video"])
    }

    func testContentHandlerRunsExactlyOnceEvenWhenTimeExpires() async throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let calls = Calls()
        let service = HeraldNotificationService()
        let request = UNNotificationRequest(identifier: "r1", content: content([:]), trigger: nil)
        service.didReceive(request) { _ in calls.lock.withLock { calls.count += 1 } }
        service.serviceExtensionTimeWillExpire()
        try await Task.sleep(nanoseconds: 300_000_000)
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(calls.lock.withLock { calls.count }, 1)
    }
}

final class ActionCategoryTests: XCTestCase {
    private let json = #"[{"id":"a1","title":"Open","deeplink":"lumen://a"},{"id":"a2","title":"Later"},{"id":""},{"id":"a3","title":"C"},{"id":"a4","title":"D"}]"#

    func testReplacesOnlyHeraldCategories() {
        XCTAssertTrue(HeraldRichPush.replacesCategory(""))
        XCTAssertTrue(HeraldRichPush.replacesCategory("herald.actions"))
        XCTAssertFalse(HeraldRichPush.replacesCategory("workout_reminder"))
    }

    func testParsesActions() {
        XCTAssertEqual(HeraldRichPush.actions(json).map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(HeraldRichPush.actions([["id": "x", "title": "X"]]).map(\.title), ["X"])
        XCTAssertTrue(HeraldRichPush.actions("nope").isEmpty)
    }

    func testRegistersCategoryAndReusesIdenticalOne() throws {
        let buttons = HeraldRichPush.actions(json)
        let app = UNNotificationCategory(identifier: "app", actions: [], intentIdentifiers: [])
        let (id, set) = HeraldRichPush.register(buttons, existing: [app], now: Date(timeIntervalSince1970: 100))
        let categories = try XCTUnwrap(set)
        XCTAssertTrue(id.hasPrefix("herald.actions.") && id.hasSuffix(".100"))
        XCTAssertEqual(categories.first { $0.identifier == id }?.actions.map(\.identifier), ["a1", "a2", "a3"])
        XCTAssertTrue(categories.contains(app))
        let again = HeraldRichPush.register(buttons, existing: categories, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(again.id, id)
        XCTAssertNil(again.categories)
    }

    func testKeepsOnlyNewestHeraldCategories() throws {
        var existing: Set<UNNotificationCategory> = [UNNotificationCategory(identifier: "app", actions: [], intentIdentifiers: [])]
        for n in 1...12 {
            existing.insert(UNNotificationCategory(identifier: "herald.actions.h\(n).\(n)", actions: [], intentIdentifiers: []))
        }
        let (id, set) = HeraldRichPush.register([("x", "X")], existing: existing, now: Date(timeIntervalSince1970: 1000))
        let categories = try XCTUnwrap(set)
        let herald = categories.map(\.identifier).filter { $0.hasPrefix("herald.actions.") }
        XCTAssertEqual(herald.count, HeraldRichPush.maxActionCategories)
        XCTAssertTrue(herald.contains(id))
        XCTAssertFalse(herald.contains("herald.actions.h3.3"), "oldest dropped")
        XCTAssertTrue(herald.contains("herald.actions.h12.12"))
        XCTAssertTrue(categories.contains { $0.identifier == "app" })
    }
}
