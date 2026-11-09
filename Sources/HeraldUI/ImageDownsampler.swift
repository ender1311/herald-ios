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
