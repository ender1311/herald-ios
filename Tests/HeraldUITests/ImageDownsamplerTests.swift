import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HeraldUI

final class ImageDownsamplerTests: XCTestCase {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testTallImageIsDecodedAtTheRequestedSize() throws {
        let url = try writePNG(width: 300, height: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(ImageDownsampler.downsample(fileAt: url, maxPixelSize: 120))
        XCTAssertEqual(max(image.width, image.height), 120)
        XCTAssertEqual(image.width, 12)
    }

    func testRequestedSizeIsCapped() throws {
        let url = try writePNG(width: 5000, height: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(ImageDownsampler.downsample(fileAt: url, maxPixelSize: 100_000))
        XCTAssertEqual(image.width, ImageDownsampler.maxPixelSize)
    }

    func testNotAnImage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ImageDownsampler.downsample(fileAt: url, maxPixelSize: 100))
    }

    func testOnlyRemoteAndBundleURLsAreAllowed() {
        let bundle = URL(fileURLWithPath: "/apps/Lumen.app")
        XCTAssertTrue(ImageDownsampler.isAllowed(URL(string: "https://x.test/a.png")!, bundleURL: bundle))
        XCTAssertTrue(ImageDownsampler.isAllowed(URL(string: "http://x.test/a.png")!, bundleURL: bundle))
        XCTAssertTrue(ImageDownsampler.isAllowed(URL(fileURLWithPath: "/apps/Lumen.app/hero.webp"), bundleURL: bundle))
        XCTAssertFalse(ImageDownsampler.isAllowed(URL(fileURLWithPath: "/apps/Lumen.app/../secret.db"), bundleURL: bundle))
        XCTAssertFalse(ImageDownsampler.isAllowed(URL(fileURLWithPath: "/apps/Lumen.appx/a.png"), bundleURL: bundle))
        XCTAssertFalse(ImageDownsampler.isAllowed(URL(fileURLWithPath: "/var/mobile/Documents/a.png"), bundleURL: bundle))
        XCTAssertFalse(ImageDownsampler.isAllowed(URL(string: "data:image/png;base64,AAAA")!, bundleURL: bundle))
    }
}
