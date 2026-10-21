import Testing
import Foundation
import UIKit
@testable import SwipeSort

@Suite("Grid architecture behavior")
@MainActor
struct GridArchitectureTests {

    @Test("identifiers(in:) resolves full ranges quickly without per-cell task lookups")
    func batchResolutionSuccess() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)

        let ids = await mock.identifiers(in: 0..<10_000)
        #expect(ids.count == 10_000)
        #expect(ids[0] == AssetIdentifier("mock-asset-0"))
        #expect(ids[9999] == AssetIdentifier("mock-asset-9999"))
    }

    @Test("GridScrollTracker tracks visible indices without mutating view @State")
    func scrollTrackerVisibleTracking() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 100)
        let cache = WindowedThumbnailCache(library: mock, targetSize: CGSize(width: 100, height: 100))
        let tracker = GridScrollTracker(cache: cache)

        #expect(tracker.minVisibleIndex == nil)
        tracker.onAppear(index: 5, total: 100)
        tracker.onAppear(index: 6, total: 100)
        tracker.onAppear(index: 7, total: 100)
        #expect(tracker.minVisibleIndex == 5)
        #expect(tracker.maxVisibleIndex == 7)

        tracker.onDisappear(index: 5, total: 100)
        #expect(tracker.minVisibleIndex == 6)

        tracker.stopAll()
        #expect(tracker.minVisibleIndex == nil)
    }
}
