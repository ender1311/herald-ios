import Foundation
import ImageIO

/// Decodes images at the size they are drawn, never at full resolution: a 6000 x 8000 photo would
/// otherwise take about 190 MB of memory per image.
enum ImageDownsampler {
    /// Largest image file the default views download.
    static let maxBytes = 20 * 1024 * 1024
    /// Upper bound on the decoded long edge, whatever the view size.
    static let maxPixelSize = 4096

    /// A thumbnail whose long edge is at most `maxPixelSize`, or nil when the file is not an image.
    static func downsample(fileAt url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixelSize, Self.maxPixelSize)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The body of a 2xx response, or nil. Enforces `limit` while downloading: a declared Content-Length
    /// over it is refused before the body is read, and reading stops as soon as the body passes it.
    static func download(_ url: URL, session: URLSession = .shared, limit: Int = maxBytes) async -> Data? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                http.expectedContentLength <= Int64(limit)
            else {
                bytes.task.cancel()
                return nil
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    return nil
                }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    /// Remote images over https or http (subject to App Transport Security), and files inside the app
    /// bundle (sample and preview assets). Never other local files: a URL comes from the server.
    static func isAllowed(_ url: URL, bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https", "http":
            return true
        case "file":
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(bundle + "/")
        default:
            return false
        }
    }
}
