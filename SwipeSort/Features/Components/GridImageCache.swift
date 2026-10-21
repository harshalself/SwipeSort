import UIKit

// MARK: - Image Cache

/// A memory cache shared across all `ThumbnailCell` instances in a grid.
///
/// Stored in a view's `@State` so it persists for the lifetime of the
/// tab and is freed automatically when the tab is torn down. `NSCache` is
/// thread-safe and auto-evicts entries under memory pressure without any
/// manual eviction logic.
///
/// Cost is set to the image's approximate byte size (width × height × 4 for
/// RGBA) so large photos are evicted before small ones when the 80 MB limit
/// is approached.
@MainActor
final class GridImageCache {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600                       // max items
        c.totalCostLimit = 80 * 1024 * 1024      // ~80 MB hard cap
        return c
    }()
    private var kinds: [String: MediaKind] = [:]

    func image(for id: AssetIdentifier) -> UIImage? {
        cache.object(forKey: id.rawValue as NSString)
    }

    func store(_ image: UIImage, for id: AssetIdentifier) {
        // `UIImage.size` is in points; on a 3× device a 400 pt image is
        // backed by a 1200 px buffer. Using points understates cost by up to
        // 9×, letting NSCache silently grow far past its declared 80 MB cap.
        // `cgImage.width/height` returns the true pixel buffer dimensions.
        let pixelW = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let pixelH = image.cgImage?.height ?? Int(image.size.height * image.scale)
        let cost = pixelW * pixelH * 4
        cache.setObject(image, forKey: id.rawValue as NSString, cost: cost)
    }

    func mediaKind(for id: AssetIdentifier) -> MediaKind? {
        kinds[id.rawValue]
    }

    func store(_ kind: MediaKind, for id: AssetIdentifier) {
        kinds[id.rawValue] = kind
    }

    /// Removes media-kind entries for assets outside the active set. Called
    /// after each `loadAssets` so the dictionary stays bounded across filter
    /// changes (the previous behavior accumulated a stale entry per asset per
    /// filter switch, unbounded).
    func trimKinds(keeping ids: [AssetIdentifier]) {
        let keepSet = Set(ids.map(\.rawValue))
        kinds = kinds.filter { keepSet.contains($0.key) }
    }
}
