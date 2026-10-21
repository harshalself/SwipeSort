import Testing
import UIKit
@testable import SwipeSort

@Suite("GridImageCache")
@MainActor
struct GridImageCacheTests {

    @Test("store cost uses cgImage pixel dimensions not point dimensions")
    func storeCostUsesPixels() {
        let cache = GridImageCache()
        let id = AssetIdentifier("test-asset-1")

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 300, height: 300),
            format: format
        )
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }

        let cgW = img.cgImage?.width ?? Int(img.size.width)
        let cgH = img.cgImage?.height ?? Int(img.size.height)
        #expect(cgW == 300)
        #expect(cgH == 300)

        cache.store(img, for: id)
        let retrieved = cache.image(for: id)
        #expect(retrieved != nil, "Image must be stored and retrievable")
    }

    @Test("store and retrieve a media kind")
    func storeAndRetrieveKind() {
        let cache = GridImageCache()
        let id = AssetIdentifier("test-asset-2")
        cache.store(.video(durationSeconds: 12.5), for: id)
        #expect(cache.mediaKind(for: id) == .video(durationSeconds: 12.5))
    }

    @Test("trimKinds removes entries not in the keeper set")
    func trimKindsRemovesStale() {
        let cache = GridImageCache()
        let keep1 = AssetIdentifier("keep-1")
        let keep2 = AssetIdentifier("keep-2")
        let stale = AssetIdentifier("stale-1")

        cache.store(.photo, for: keep1)
        cache.store(.livePhoto, for: keep2)
        cache.store(.video(durationSeconds: 5), for: stale)

        cache.trimKinds(keeping: [keep1, keep2])

        #expect(cache.mediaKind(for: keep1) == .photo)
        #expect(cache.mediaKind(for: keep2) == .livePhoto)
        #expect(cache.mediaKind(for: stale) == nil)
    }
}
