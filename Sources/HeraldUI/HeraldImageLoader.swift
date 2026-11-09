#if os(iOS)
import os
import UIKit

/// Downloads to a file, downsamples to the drawn size and caches by cost (decoded bytes). Work is
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
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: url)
                temporary = downloaded
                let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                    size > 0, size <= ImageDownsampler.maxBytes
                else { return nil }
                file = downloaded
            } catch {
                return nil
            }
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
