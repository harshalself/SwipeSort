import Testing
import Foundation
import UIKit
@testable import SwipeSort

@Suite("ApplyFilterRefresh")
@MainActor
struct ApplyFilterRefreshTests {

    @Test("applyFilter with unchanged filter still yields identifiers")
    func applyFilterUnchangedStillRefreshes() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.scriptedFilteredCount = 3

        await mock.applyFilter(.unfiltered)
        let ids1 = await mock.identifiers(in: 0..<3)

        await mock.applyFilter(.unfiltered)
        let ids2 = await mock.identifiers(in: 0..<3)

        #expect(ids1.count == 3)
        #expect(ids2.count == 3)
        #expect(ids1 == ids2)
    }

    @Test("loadAssets-style sequence: applyFilter alone matches applyFilter+refreshFetchResult")
    func loadAssetsSequenceAppliesFilterOnce() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10)

        _ = await mock.refreshFetchResult()
        await mock.applyFilter(.unfiltered)
        let idsOldPattern = await mock.identifiers(in: 0..<5)

        await mock.applyFilter(.unfiltered)
        let idsNewPattern = await mock.identifiers(in: 0..<5)

        #expect(idsOldPattern == idsNewPattern,
            "omitting refreshFetchResult must produce identical identifiers — the call was redundant")
    }

    @Test("applyFilter mid-session does not reset the cursor or corrupt subsequent swipe")
    func applyFilterMidSessionDoesNotResetCursor() async {
        // PRODUCTION GAP: PhotoLibraryReadProviding.applyFilter is documented as
        // "before start() only" but no runtime guard enforces it. This test pins
        // the current mock behavior — applying a filter mid-session records it but
        // does not corrupt cursor state. If production ever adds a precondition or
        // a session-reset on mid-session filter change, this test must be updated.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 1, height: 1))
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.phase == .ready)

        // Mid-session filter change — the mock records the filter but does not
        // rebuild the fetch cursor. currentIndex is preserved.
        var newFilter = SwipeFilter.unfiltered
        newFilter.mediaType = .videosOnly
        await mock.applyFilter(newFilter)
        #expect(mock.appliedFilter == newFilter,
            "mock must have recorded the mid-session filter change")

        // Subsequent swipe advances normally — the current asset id is still valid.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeFavorite()
        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        #expect(m.currentIndex == 1)
        #expect(m.phase == .ready)
    }
}
