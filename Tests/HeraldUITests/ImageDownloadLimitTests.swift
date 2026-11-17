import XCTest
@testable import HeraldUI

/// Serves a canned body, optionally declaring a Content-Length, and counts how much it was asked to send.
final class ImageStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var contentLength: String?
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers = ["Content-Type": "image/png"]
        if let length = Self.contentLength { headers["Content-Length"] = length }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// audit 2026-11-17: iOS HeraldUI image loader downloads the whole file before applying the 20 MB limit
final class ImageDownloadLimitTests: XCTestCase {
    private let url = URL(string: "https://img.example.com/a.png")!

    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageStubProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        ImageStubProtocol.body = Data()
        ImageStubProtocol.contentLength = nil
        ImageStubProtocol.status = 200
    }

    func testBodyWithinTheLimitIsReturned() async {
        ImageStubProtocol.body = Data(repeating: 1, count: 100)
        let data = await ImageDownsampler.download(url, session: session, limit: 100)
        XCTAssertEqual(data?.count, 100)
    }

    func testBodyPastTheLimitIsRefusedWithoutAContentLength() async {
        ImageStubProtocol.body = Data(repeating: 1, count: 101)
        let data = await ImageDownsampler.download(url, session: session, limit: 100)
        XCTAssertNil(data)
    }

    func testDeclaredContentLengthPastTheLimitIsRefused() async {
        ImageStubProtocol.body = Data(repeating: 1, count: 10)
        ImageStubProtocol.contentLength = "1000"
        let data = await ImageDownsampler.download(url, session: session, limit: 100)
        XCTAssertNil(data)
    }

    func testErrorStatusAndEmptyBodyAreRefused() async {
        ImageStubProtocol.body = Data(repeating: 1, count: 10)
        ImageStubProtocol.status = 404
        let notFound = await ImageDownsampler.download(url, session: session, limit: 100)
        XCTAssertNil(notFound)
        ImageStubProtocol.status = 200
        ImageStubProtocol.body = Data()
        let empty = await ImageDownsampler.download(url, session: session, limit: 100)
        XCTAssertNil(empty)
    }
}
