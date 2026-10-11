import SwiftUI
import UIKit

/// Photos and avatars, kept in memory once loaded so scrolling back or switching tabs doesn't flash a placeholder.
/// Every upload gets a new file name, so a cached image never goes stale.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    private func key(_ url: URL, _ maxPixels: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(maxPixels))" as NSString }

    func cached(_ url: URL, maxPixels: CGFloat) -> UIImage? { cache.object(forKey: key(url, maxPixels)) }

    func load(_ url: URL, maxPixels: CGFloat) async -> UIImage? {
        let k = key(url, maxPixels)
        if let image = cache.object(forKey: k) { return image }
        if let task = loading[k as String] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            // Decode at the size it's shown, off the main thread, so big photos don't stutter the scroll.
            let scale = min(1, maxPixels / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return await image.byPreparingThumbnail(ofSize: size) ?? image
        }
        loading[k as String] = task
        let image = await task.value
        loading[k as String] = nil
        if let image {
            cache.setObject(image, forKey: k, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

/// A remote photo that fills its frame (or, with `fit`, keeps its own shape), with a placeholder until it loads.
struct RemoteImage<Placeholder: View>: View {
    let url: URL
    /// Longest side to decode, in pixels.
    var maxPixels: CGFloat = 1200
    /// Show the whole photo at its own shape instead of cropping it to fill.
    var fit = false
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    private var image: UIImage? {
        if let loaded, loaded.url == url { return loaded.image }
        return ImageCache.shared.cached(url, maxPixels: maxPixels)
    }

    var body: some View {
        Group {
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard image == nil, let fetched = await ImageCache.shared.load(url, maxPixels: maxPixels) else { return }
            loaded = (url, fetched)
        }
    }
}
