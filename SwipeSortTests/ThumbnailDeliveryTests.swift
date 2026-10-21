import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("Thumbnail delivery boundary cases")
struct ThumbnailDeliveryTests {

    private let targetSize = CGSize(width: 1, height: 1)

    @Test("nil thumbnail on start leaves currentThumbnail nil but phase reaches .ready")
    func nilThumbnailOnStart() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        // Script mock-asset-0 (currentThumbnail load) to return nil.
        // Next/prev pre-fetches for mock-asset-1 inside the same loadCurrent() consume the default path.
        mock.scriptedThumbnails["mock-asset-0"] = .some(nil)

        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        // No crash. Phase reached .ready (loadInitial sets .ready after loadCurrent).
        #expect(m.phase == .ready,
            "session must still reach .ready even when the first thumbnail is nil")
        #expect(m.currentThumbnail == nil,
            "nil scripted thumbnail must be assigned directly with no fallback synthesis")
        #expect(m.totalCount == 2)
        #expect(m.currentIndex == 0)
    }

    @Test("degraded thumbnail flows through with isDegraded == true")
    func degradedThumbnailOnStart() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let degraded = AssetThumbnail(
            identifier: AssetIdentifier("mock-asset-0"),
            image: img,
            isDegraded: true
        )
        mock.nextThumbnailResult = .some(degraded)

        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        #expect(m.currentThumbnail?.isDegraded == true,
            "the degraded flag must be preserved end-to-end from the mock to the model")
        #expect(m.currentThumbnail?.identifier.rawValue == "mock-asset-0")
        #expect(m.phase == .ready)
    }
}

// ⚠️ Human: add `SwipeSortTests/ThumbnailDeliveryTests.swift` to the SwipeSortTests Xcode target.
