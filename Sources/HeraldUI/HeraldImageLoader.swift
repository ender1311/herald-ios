#if os(iOS)
import os
import UIKit

/// Downloads (at most `ImageDownsampler.maxBytes`) to a file, downsamples to the drawn size and caches by cost (decoded bytes). Work is
/// cancelled with the view's task.
@MainActor
final class HeraldImageLoader {
    static let shared = HeraldImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static func key(_ url: URL, _ maxPixelSize: Int) -> NSString { "\(url.absoluteString)#\(maxPixelSize)" as NSString }

    func cached(_ url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: Self.key(url, maxPixelSize))
    }

    func load(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        if let image = cached(url, maxPixelSize: maxPixelSize) { return image }
        guard ImageDownsampler.isAllowed(url) else { return nil }
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        let file: URL
        if url.isFileURL {
            file = url
        } else {
            guard let data = await ImageDownsampler.download(url) else { return nil }
            let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            temporary = downloaded
            do {
                try data.write(to: downloaded)
            } catch {
                return nil
            }
            file = downloaded
        }
        guard !Task.isCancelled else { return nil }
        let cgImage = await Task.detached(priority: .utility) {
            ImageDownsampler.downsample(fileAt: file, maxPixelSize: maxPixelSize)
        }.value
        guard let cgImage else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: Self.key(url, maxPixelSize), cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
#endif
