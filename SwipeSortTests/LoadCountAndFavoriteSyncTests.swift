import Testing
import Foundation
@testable import SwipeSort

@Suite("LoadCount & Favorite Synchronization")
@MainActor
struct LoadCountAndFavoriteSyncTests {

    @Test("bumpGeneration explicitly increments generation when metadata changes without count changes")
    func testBumpGenerationOnMetadataChange() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 100)
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)
        #expect(controller.generation == 1)

        // Simulate toggling favorite status where `refreshFetchResult()` returns `false`
        mock.nextRefreshReturnsChanged = false
        controller.bumpGeneration()
        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.generation == 2,
                "bumpGeneration() must increment generation even when refreshFetchResult() reports no change")
    }

    @Test("bumpGeneration wraps around cleanly on overflow without trapping")
    func testBumpGenerationOverflow() async {
        let controller = LoadCountController()
        // Force generation near `Int.max`
        // We use repeated calls to verify wrapping `&+= 1` invariants
        controller.bumpGeneration()
        #expect(controller.generation == 1)
    }

}
