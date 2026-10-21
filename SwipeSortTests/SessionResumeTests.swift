import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("Session resume & navigation")
struct SessionResumeTests {

    private let targetSize = CGSize(width: 300, height: 400)

    @Test("start respects initialIndex")
    func startAtInitialIndex() async throws {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let m = SwipeSessionModel(library: mock, initialIndex: 2, targetSize: targetSize)
        await m.start()

        #expect(m.phase == .ready)
        #expect(m.currentThumbnail?.identifier.rawValue == "mock-asset-2")
    }

    @Test("finishes immediately if library has 0 assets")
    func emptyLibraryFinishes() async throws {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 0)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .finished)
    }

    @Test("swipeDelete queues deletion decision")
    func swipeDeleteQueuesDecision() async throws {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeDelete()

        #expect(m.pendingDeletions.contains(AssetIdentifier("mock-asset-0")))
    }

    @Test("undo removes the identifier from deletion queue")
    func undoRemovesDecision() async throws {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeDelete()
        #expect(m.pendingDeletions.contains(AssetIdentifier("mock-asset-0")))
        await m.undo()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(!m.pendingDeletions.contains(AssetIdentifier("mock-asset-0")))
    }

    @Test("undo from .finished restores .ready phase and reloads currentThumbnail")
    func undoFromFinishedRestoresReadyPhase() async {
        // 2-asset session; swipe both to reach .finished; then undo.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeFavorite()   // 0 → decided
        await m.swipeFavorite()   // 1 → decided → phase transitions to .finished
        #expect(m.phase == .finished)
        #expect(m.currentThumbnail == nil,
            "after finishing, the current thumbnail must be cleared")

        // Undo should transition back to .ready AND repopulate currentThumbnail.
        await m.undo()
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(m.phase == .ready,
            "undo from .finished must transition phase back to .ready")
        #expect(m.currentThumbnail != nil,
            "undo from .finished must reload currentThumbnail so the deck is renderable")
        #expect(m.currentIndex == 1,
            "undo must position the cursor on the asset whose decision was popped")
    }
}
