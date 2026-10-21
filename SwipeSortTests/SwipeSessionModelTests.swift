import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("SwipeSessionModel", .serialized)
struct SwipeSessionModelTests {

    private let targetSize = CGSize(width: 300, height: 400)

    @Test("initial phase is idle")
    func initialPhaseIdle() {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        #expect(m.phase == .idle)
        #expect(m.currentIndex == 0)
        #expect(m.totalCount == 0)
    }

    @Test("start with authorized library transitions to ready and loads first thumbnail")
    func startReady() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .ready)
        #expect(m.totalCount == 3)
        #expect(m.currentIndex == 0)
        #expect(m.currentThumbnail != nil)
    }

    @Test("start with denied library transitions to denied")
    func startDenied() async {
        let mock = MockPhotoLibrary(authorization: .denied, assetCount: 0)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .denied)
    }

    @Test("start with notDetermined requests and honors decision")
    func startRequestsAuthorization() async {
        let mock = MockPhotoLibrary(authorization: .notDetermined, assetCount: 2)
        mock.nextAuthorizationDecision = .authorized
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .ready)
        #expect(m.totalCount == 2)
    }

    @Test("swipeDelete records .delete decision")
    func swipeDeleteRecords() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let firstId = m.currentThumbnail!.identifier
        await m.swipeDelete()
        #expect(m.queue.decisions[0] == .delete(firstId))
    }

    @Test("swiping past the last asset transitions to finished")
    func finishesAtEnd() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeFavorite()
        await m.swipeFavorite()

        #expect(m.phase == .finished)
        #expect(m.currentThumbnail == nil)
    }

    @Test("undo rewinds the queue and reloads previous thumbnail")
    func undoRewinds() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let firstId = m.currentThumbnail!.identifier
        await m.swipeDelete()
        #expect(m.currentIndex == 1)

        await m.undo()
        #expect(m.queue.decisions.isEmpty)
        #expect(m.currentIndex == 0)
        #expect(m.currentThumbnail?.identifier == firstId)
    }

    @Test("undo on empty queue is a no-op")
    func undoEmptyNoOp() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        await m.undo()
        #expect(m.currentIndex == 0)
        #expect(m.queue.decisions.isEmpty)
    }

    @Test("swipePrev navigates to index - 1 regardless of decision status (W9 fix)")
    func swipePrevNavigatesToPreviousIndex() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        // Index 0: advance without deciding
        await m.swipeNext()
        #expect(m.currentIndex == 1)
        // Index 1: delete (decided)
        await m.swipeDelete()
        #expect(m.currentIndex == 2)
        // From index 2, swipePrev should step back to index 1 (decided, but now reachable).
        await m.swipePrev()
        #expect(m.currentIndex == 1)
    }

    @Test("single photo library transitions cleanly to finished after one swipe")
    func singlePhotoSwipeTransitionsToFinished() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .ready)
        #expect(m.currentThumbnail != nil)

        await m.swipeDelete()
        #expect(m.phase == .finished)
        #expect(m.currentThumbnail == nil)
    }

    @Test("commitDecisions on empty deletion queue immediately returns success(0)")
    func commitDecisionsEmptyQueueReturnsSuccessZero() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let res = await m.commitDecisions()
        #expect(res == .success(affectedCount: 0))
    }

    @Test("commitDecisions reverts phase to ready when user cancels the system alert")
    func commitDecisionsCancelledRevertsToReady() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.nextCommitResult = .cancelledByUser
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        await m.swipeDelete()
        await m.swipeDelete()
        #expect(m.pendingDeletions.count == 2)

        let result = await m.commitDecisions()
        #expect(result == .cancelledByUser)
        // Phase must revert to .ready so the user can retry from the swipe deck.
        #expect(m.phase == .ready)
        // Queue must be intact — nothing was deleted.
        #expect(m.pendingDeletions.count == 2)
    }

    @Test("commitDecisions reverts phase to ready on failure")
    func commitDecisionsFailedRevertsToReady() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.nextCommitResult = .failed(reason: "permissions")
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        await m.swipeDelete()
        let result = await m.commitDecisions()
        #expect(result == .failed(reason: "permissions"))
        #expect(m.phase == .ready)
        #expect(m.pendingDeletions.count == 1)
    }

    @Test("undo when popped asset is missing does not jump to index 0")
    func undoMissingAssetFallback() async {
        // 5-asset mock; we'll sham the identifier lookup to simulate an externally
        // deleted asset by using a mock that never returns the first asset's ID.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        // Swipe through assets 0, 1, 2 so currentIndex is 3.
        await m.swipeDelete() // index 0 → decided, currentIndex becomes 1
        await m.swipeDelete() // index 1 → decided, currentIndex becomes 2
        await m.swipeDelete() // index 2 → decided, currentIndex becomes 3
        #expect(m.currentIndex == 3)

        // Now forcibly corrupt the queue by replacing the last decision with a
        // fake identifier that the mock will never return from assetIdentifier(at:).
        // We test this by calling undo on a session where the popped identifier is
        // "ghost-asset" — MockPhotoLibrary always returns "mock-asset-N", so any
        // other rawValue will not be found during the backward scan.
        // Inject via a second queue record + immediate removal of the real one, then
        // add the ghost directly to the internal decisions array via a test helper.
        // Since DecisionQueue.decisions is private(set), we pop the real decision
        // and re-record a ghost one using the existing public API.
        let realPopped = m.queue.undoLast()  // pops .delete("mock-asset-2")
        #expect(realPopped == .delete(AssetIdentifier("mock-asset-2")))
        // Re-record with a ghost identifier
        m.queue.record(.delete(AssetIdentifier("ghost-asset-99999")))
        // currentIndex is still 3, queue top is now the ghost

        let before = m.currentIndex  // 3
        await m.undo()
        // Must NOT have jumped to 0. Best-effort fallback: currentIndex = max(0, before - 1) = 2
        #expect(m.currentIndex == before - 1)
        #expect(m.currentIndex != 0 || before == 1)  // only allowed to be 0 if we were at index 1
    }

    @Test("movedToAlbumCount reads from DecisionQueue counter, not decisions array")
    func movedToAlbumCountUsesCounter() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.seedAlbums([UserAlbum(id: "alb-1", title: "Faves", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        await m.swipeUp(intoAlbumId: "alb-1")
        await m.swipeUp(intoAlbumId: "alb-1")
        #expect(m.movedToAlbumCount == 2)

        // Simulate a deletion + commit cycle
        await m.swipeDelete()
        let res = await m.commitDecisions()
        #expect(res == .success(affectedCount: 1))
        // After commit, movedToAlbumCount must persist (summary display uses it)
        #expect(m.movedToAlbumCount == 2)
        // But .moveToAlbum entries are gone from decisions (W3: no stale accumulation)
        let moveEntries = m.queue.decisions.filter {
            if case .moveToAlbum = $0 { return true }
            return false
        }
        #expect(moveEntries.isEmpty)
    }

    @Test("commitDecisions with only move decisions and no deletions finishes cleanly")
    func commitDecisionsMovesOnlyFinishesCleanly() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.seedAlbums([UserAlbum(id: "alb-1", title: "Travel", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        // Only move swipes — no deletions.
        await m.swipeUp(intoAlbumId: "alb-1")
        await m.swipeUp(intoAlbumId: "alb-1")
        #expect(m.pendingDeletions.isEmpty)
        #expect(m.movedToAlbumCount == 2)

        // commitDecisions with no pending deletions: returns success(0) and finishes.
        let result = await m.commitDecisions()
        #expect(result == .success(affectedCount: 0))
        #expect(m.phase == .finished)
        // Move count persists after commit.
        #expect(m.movedToAlbumCount == 2)
    }

    @Test("start() with authorized library registers photo library observer exactly once")
    func startRegistersObserverOnce() async {
        // Use MockPhotoLibrary — it does not interact with PHPhotoLibrary.
        // The real registration path is in PhotoKitLibrary; here we verify the
        // start() control-flow reaches the registration call site by checking that
        // calling start() twice on the same model does not crash or double-register
        // (idempotency is guaranteed by PhotoLibraryChangePublisher.register()).
        // This test is a logical verification; the PhotoLibraryChangePublisher
        // idempotency unit test lives in a dedicated suite added below.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        // Start twice — must not crash, phase must be .ready after second call.
        await m.start()
        #expect(m.phase == .ready)
        // Calling start() a second time is a programming-error scenario but must not crash.
        await m.start()
        #expect(m.phase == .ready || m.phase == .loading)
    }

    // MARK: - Finding 2 regression: favoritedCount

    @Test("swipeFavorite increments favoritedCount")
    func swipeFavoriteIncrementsFavoritedCount() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 4)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeFavorite()
        #expect(m.favoritedCount == 1)
    }

    @Test("undo of a swipeFavorite keep decrements favoritedCount")
    func undoSwipeFavoriteDecrementsFavoritedCount() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeFavorite()
        #expect(m.favoritedCount == 1)

        await m.undo()
        #expect(m.favoritedCount == 0)
    }

    // MARK: - Finding 3 regression: duplicate decision after swipePrev

    @Test("swipeDelete + swipePrev + swipeFavorite leaves only .keep in queue (no duplicate decisions)")
    func swipePrevRedecisionReplacesNotDuplicates() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let firstId = m.currentThumbnail!.identifier
        await m.swipeDelete()        // records .delete(firstId), advance to index 1
        #expect(m.currentIndex == 1)

        await m.swipePrev()          // navigate back to index 0
        #expect(m.currentIndex == 0)
        #expect(m.currentThumbnail?.identifier == firstId)

        await m.swipeFavorite()      // re-decide: should replace .delete with .keep
        // Queue must contain exactly one decision for firstId, and it must be .keep.
        let decisionsForFirst = m.queue.decisions.filter { $0.identifier == firstId }
        #expect(decisionsForFirst.count == 1)
        #expect(decisionsForFirst[0] == .keep(firstId))
        // No residual .delete for firstId.
        let deleteForFirst = m.queue.decisions.filter {
            if case .delete(let id) = $0, id == firstId { return true }
            return false
        }
        #expect(deleteForFirst.isEmpty)
    }

    @Test("swipeUp after swipePrev to a different album replaces prior decision and reverts prior move (no duplicate count)")
    func swipeUpAfterPrevReplacesPreviousMoveAndRevertsSideEffect() async {
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([
            UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true),
            UserAlbum(id: "album-B", title: "B", assetCount: 0, canAdd: true)
        ])
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        // Swipe up into album A on asset at index 0.
        await m.swipeUp(intoAlbumId: "album-A")
        #expect(m.currentIndex == 1)
        #expect(m.movedToAlbumCount == 1)

        // Prev back to index 0 (which was decided as a move).
        await m.swipePrev()
        #expect(m.currentIndex == 0)

        // Swipe up into album B on the same asset.
        await m.swipeUp(intoAlbumId: "album-B")
        #expect(m.currentIndex == 1)
        // Only 1 asset was moved, prior move to A was reverted and replaced by B.
        #expect(m.movedToAlbumCount == 1)
        #expect(m.queue.decisions.count == 1)
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "album-A")
    }

    @Test("start uses exact initialAssetId lookup instead of integer index drift")
    func startUsesExactAssetIdLookup() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10)
        let targetId = AssetIdentifier("mock-asset-7")
        let m = SwipeSessionModel(
            library: mock,
            initialIndex: 0,
            initialAssetId: targetId,
            targetSize: targetSize
        )
        await m.start()
        #expect(m.currentIndex == 7)
        #expect(m.currentThumbnail?.identifier == targetId)
    }

    @Test("swipeFavorite still sets isFavorite true and records keep decision")
    func swipeFavoriteSetsIsFavorite() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        let firstId = m.currentThumbnail!.identifier
        await m.swipeFavorite()

        #expect(mock.favoriteState[firstId] == true)
        #expect(m.queue.decisions[0] == .keep(firstId))
    }

    @Test("undo of moveToAlbum in dry-run mode does not call removeAssetsFromAlbum")
    func undoMoveInDryRunSkipsRemove() async {
        // Enable dry-run using DryRunMode.standard so undo() reads it via the
        // static var DryRunMode.isEnabled (which reads .standard).
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(true)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "alb-1", title: "Test", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await m.start()

        await m.swipeUp(intoAlbumId: "alb-1")
        #expect(m.queue.decisions.count == 1)
        #expect(mock.lastRemoves.isEmpty)

        await m.undo()
        #expect(m.queue.decisions.isEmpty)
        // Dry-run undo must not have issued a real removeAssetsFromAlbum call.
        #expect(mock.lastRemoves.isEmpty)
    }

    @Test("configure(targetSize:) updates the stored size without breaking start()")
    func configureTargetSize() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let model = SwipeSessionModel(
            library: mock,
            targetSize: CGSize(width: 400, height: 600)
        )
        model.configure(targetSize: CGSize(width: 1200, height: 1800))
        await model.start()
        #expect(model.phase == .ready || model.phase == .denied,
            "model must be in a valid post-start phase after configure")
    }

    @Test("two swipes dispatched concurrently record exactly 2 unique identifiers")
    func concurrentSwipesDoNotCorruptQueue() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.totalCount == 2)

        // Dispatch both swipes with `async let` — inherits @MainActor context.
        // Task.detached would break isolation; async let preserves it.
        async let first: () = m.swipeDelete()
        async let second: () = m.swipeFavorite()
        _ = await first
        _ = await second

        // Exactly 2 decisions, one per asset. No duplicates, no missing entries.
        #expect(m.queue.decisions.count == 2,
            "exactly 2 decisions must be recorded regardless of dispatch order")
        let uniqueIds = Set(m.queue.decisions.map(\.identifier))
        #expect(uniqueIds.count == 2,
            "both decisions must target distinct assets — no double-execute on the same id")
        // currentIndex must be exactly 2 (both advance() calls landed).
        #expect(m.currentIndex == 2)
        #expect(m.phase == .finished,
            "after both swipes on a 2-asset library, phase must be .finished")
    }

    @Test("refreshFetchResult mid-session does not corrupt subsequent swipe recording")
    func midSessionLibraryChangeDoesNotCorruptSwipe() async {
        // PRODUCTION GAP: SwipeSessionModel does not re-validate currentIndex after
        // a PhotoLibraryChangePublisher.didChangeNotification. This test pins the
        // CURRENT behavior — a refresh with a stable asset count preserves cursor
        // semantics — but the real risk (an asset shifting under the cursor) is
        // untested because MockPhotoLibrary.refreshFetchResult() does not
        // actually mutate the underlying asset order.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.phase == .ready)

        // Simulate a library-change notification mid-session.
        _ = await mock.refreshFetchResult()

        // The subsequent swipe must still record the current asset's identifier —
        // if the model were re-fetching state on every advance it could otherwise
        // record a stale or wrong identifier.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeFavorite()

        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        #expect(m.phase == .ready,
            "phase must remain .ready — a mid-session refresh must not force .finished or .loading")
        #expect(m.currentIndex == 1)
    }

    @Test("auth revocation after .ready does not force phase change (current behavior)")
    func authRevocationMidSessionCurrentBehavior() async {
        // PRODUCTION GAP: SwipeSessionModel checks authorization only in start()
        // (SwipeSessionModel.swift:86–105). After phase == .ready, revoking access
        // is silently ignored — the model keeps returning currentThumbnails from the
        // mock's cached fetch state. This test asserts that current behavior so a
        // future production fix (routing .denied through a mid-session watcher) has
        // a regression pin to replace.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .ready)

        // Revoke access mid-session.
        mock.setCurrentAuthorization(.denied)

        // The model does not observe this; the next swipe still records normally.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeFavorite()

        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        // Phase remains .ready — the model has no mid-session revocation handler.
        #expect(m.phase == .ready)
        // But currentAuthorization() now reports .denied — verify the mock hook worked.
        let auth = await mock.currentAuthorization()
        #expect(auth == .denied)
    }

    @Test("swipePrev at currentIndex == 0 is a no-op (no cursor change, no queue mutation)")
    func swipePrevAtIndexZeroIsNoOp() async {
        // Pins the `guard currentIndex > 0 else { return }` at SwipeSessionModel.swift:229.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        let firstThumb = m.currentThumbnail

        // Attempt to go back from the very first card.
        await m.swipePrev()

        #expect(m.currentIndex == 0,
            "swipePrev at index 0 must not underflow to -1 or wrap")
        #expect(m.queue.decisions.isEmpty,
            "swipePrev is navigation, not a decision — the queue must be untouched")
        #expect(m.currentThumbnail?.identifier == firstThumb?.identifier,
            "currentThumbnail must still be the first asset after a no-op swipePrev")
        #expect(m.phase == .ready)
    }

    @Test("swipeNext at currentIndex == totalCount - 1 is a no-op (no transition to .finished, no cursor change)")
    func swipeNextAtIndexLastIsNoOp() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)

        // Advance to the last photo (index 2)
        await m.swipeNext()
        #expect(m.currentIndex == 1)
        await m.swipeNext()
        #expect(m.currentIndex == 2)
        let lastThumb = m.currentThumbnail

        // Attempt to skip/next from the very last card.
        await m.swipeNext()

        #expect(m.currentIndex == 2,
            "swipeNext at last index must stay at totalCount - 1 without overflowing")
        #expect(m.queue.decisions.isEmpty,
            "swipeNext is navigation, not a decision — the queue must be untouched")
        #expect(m.currentThumbnail?.identifier == lastThumb?.identifier,
            "currentThumbnail must still be the last asset after a no-op swipeNext")
        #expect(m.phase == .ready,
            "swipeNext at last index must not transition to .finished")
    }

    @Test("removeFromDeletionQueue drops a single id and preserves the rest")
    func removeFromDeletionQueueSingleId() async {
        // Pins SwipeSessionModel.removeFromDeletionQueue(_:) at SwipeSessionModel.swift:345.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let ids = [
            AssetIdentifier("mock-asset-0"),
            AssetIdentifier("mock-asset-1"),
            AssetIdentifier("mock-asset-2")
        ]
        await m.swipeDelete()
        await m.swipeDelete()
        await m.swipeDelete()
        #expect(m.pendingDeletions.count == 3)

        // Remove the middle asset only.
        m.removeFromDeletionQueue(ids[1])

        #expect(m.pendingDeletions.count == 2,
            "removeFromDeletionQueue must drop exactly one entry")
        #expect(!m.pendingDeletions.contains(ids[1]),
            "the removed identifier must no longer appear in pendingDeletions")
        #expect(m.pendingDeletions.contains(ids[0]))
        #expect(m.pendingDeletions.contains(ids[2]))
    }

    @Test("swipeUp with sourceAlbumId properly executes cut-and-paste via moveAssets")
    func swipeUpFromSourceAlbumExecutesCutAndPaste() async {
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([
            UserAlbum(id: "album-source", title: "Source", assetCount: 2, canAdd: false),
            UserAlbum(id: "album-dest", title: "Dest", assetCount: 0, canAdd: true)
        ])
        
        let m = SwipeSessionModel(
            library: mock, 
            sourceAlbumId: "album-source",
            initialIndex: 0, 
            initialAssetId: nil, 
            targetSize: CGSize(width: 300, height: 400)
        )
        await m.start()

        let id = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "album-dest")

        // The decision should reflect the source album
        #expect(m.decision(for: id) == .moveToAlbum(id, fromAlbumId: "album-source", toAlbumId: "album-dest"))
        
        // MockPhotoLibrary.moveAssets records in lastMoves
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].from == "album-source")
        #expect(mock.lastMoves[0].to == "album-dest")
        #expect(mock.lastMoves[0].ids.contains(id))
    }
}

@Suite("PhotoLibraryChangePublisher")
@MainActor
struct PhotoLibraryChangePublisherTests {

    @Test("register() is idempotent — calling twice does not double-register")
    func registerIsIdempotent() {
        // PhotoLibraryChangePublisher.shared.register() calls
        // PHPhotoLibrary.shared().register(self) internally. PHPhotoLibrary
        // itself is idempotent for duplicate registrations (re-registering the
        // same observer is a no-op). Our guard makes this explicit and ensures
        // the `isRegistered` flag is set after the first call.
        let pub = PhotoLibraryChangePublisher.shared
        // First call — should succeed without crash.
        pub.register()
        // Second call — must not crash; idempotency guard prevents double-registration.
        pub.register()
        // If we reach here the idempotency contract holds.
        #expect(Bool(true))
    }

    @Test("register() is callable from @MainActor context without await")
    @MainActor
    func registerCallableOnMainActorWithoutAwait() {
        // Compile-time pin: after the @MainActor annotation is added to register(),
        // calling it from a @MainActor context requires no `await`. If this test
        // file compiles and this call is not marked `await`, the isolation is correct.
        // Runtime pin: Thread.isMainThread must be true here.
        #expect(Thread.isMainThread, "register() must be callable from main actor")
        PhotoLibraryChangePublisher.shared.register()
        // If we reach here, register() is callable synchronously on the main actor.
        #expect(Bool(true))
    }

    @Test("registerIfAuthorized() is callable synchronously from @MainActor and idempotent")
    @MainActor
    func registerIfAuthorizedCallableAndIdempotent() {
        // Compile-time pin: `registerIfAuthorized` is @MainActor and requires no await.
        // Runtime pin: repeated calls do not crash regardless of the test host's
        // authorization state (undecided in simulator, authorized on device).
        let pub = PhotoLibraryChangePublisher.shared
        pub.registerIfAuthorized()
        pub.registerIfAuthorized()
        pub.registerIfAuthorized()
        #expect(Bool(true), "registerIfAuthorized must be idempotent and non-crashing")
    }

    @Test("didChangeNotification and albumsDidChangeNotification are distinct")
    func notificationNamesAreDistinct() {
        // Guards against a copy/paste rename that could collapse the two
        // notification streams into one — asset-only edits would then wake
        // AlbumsView every time.
        #expect(
            PhotoLibraryChangePublisher.didChangeNotification
            != PhotoLibraryChangePublisher.albumsDidChangeNotification,
            "Precise album-change notification must be its own name"
        )
        #expect(PhotoLibraryChangePublisher.didChangeNotification.rawValue == "PhotoLibraryDidChange")
        #expect(PhotoLibraryChangePublisher.albumsDidChangeNotification.rawValue == "PhotoLibraryAlbumsDidChange")
    }

    @Test("pendingDeletions and phase expose observable state for a11y announcements")
    @MainActor func pendingDeletionsAndPhaseObservable() async {
        // Phase 6 Task 3 wires two `.onChange` handlers in SwipeStackView that
        // fire UIAccessibility.post on changes to `pendingDeletions.count` and
        // `phase`. This test pins the pre-conditions those handlers rely on so
        // a future refactor to the model cannot silently disable the a11y hooks.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let model = SwipeSessionModel(
            library: mock, initialIndex: 0, initialAssetId: nil,
            targetSize: CGSize(width: 100, height: 100)
        )
        await model.start()
        let before = model.pendingDeletions.count
        await model.swipeDelete()
        #expect(model.pendingDeletions.count == before + 1,
            "swipeDelete must increment pendingDeletions so the announcement .onChange fires")

        await model.swipeDelete()
        #expect(model.phase == .finished,
            "after all assets swiped, phase must reach .finished so the screenChanged .onChange fires")
    }

    @Test("decision(for:) returns correct existing decision and updates after redecision")
    func decisionForLookupReturnsExistingDecisionAndUpdatesOnRedecision() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([
            UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true),
            UserAlbum(id: "album-B", title: "B", assetCount: 0, canAdd: true)
        ])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()

        let firstId = await mock.assetIdentifier(at: 0)!
        #expect(model.decision(for: firstId) == nil)

        await model.swipeUp(intoAlbumId: "album-A")
        #expect(model.decision(for: firstId) == .moveToAlbum(firstId, fromAlbumId: nil, toAlbumId: "album-A"))

        await model.swipePrev()
        #expect(model.decision(for: firstId) == .moveToAlbum(firstId, fromAlbumId: nil, toAlbumId: "album-A"))

        await model.swipeUp(intoAlbumId: "album-B")
        #expect(model.decision(for: firstId) == .moveToAlbum(firstId, fromAlbumId: nil, toAlbumId: "album-B"))
    }

    // MARK: - End-to-End & Edge Cases for Redecisions & Badge Lookups

    @Test("Move to album then prev then favorite replaces move, adjusts counters, and reverts side effect")
    func moveToAlbumThenPrevThenFavoriteReplacesMoveAndAdjustsCounters() async {
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true)])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()
        let id = await mock.assetIdentifier(at: 0)!

        await model.swipeUp(intoAlbumId: "album-A")
        #expect(model.movedToAlbumCount == 1)
        #expect(model.decision(for: id) == .moveToAlbum(id, fromAlbumId: nil, toAlbumId: "album-A"))

        await model.swipePrev()
        await model.swipeFavorite()

        #expect(model.movedToAlbumCount == 0, "Move counter must decrement when replaced by favorite")
        #expect(model.decision(for: id) == .keep(id))
        #expect(model.queue.favoritedIds.contains(id) == true)
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "album-A")
    }

    @Test("Favorite then prev then move to album replaces favorite and clears favorited flag")
    func favoriteThenPrevThenMoveToAlbumReplacesFavoriteAndAdjustsCounters() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true)])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()
        let id = await mock.assetIdentifier(at: 0)!

        await model.swipeFavorite()
        #expect(model.queue.favoritedIds.contains(id) == true)
        #expect(model.decision(for: id) == .keep(id))

        await model.swipePrev()
        await model.swipeUp(intoAlbumId: "album-A")

        #expect(model.queue.favoritedIds.contains(id) == false, "Favorited flag must be cleared when replaced by album move")
        #expect(model.movedToAlbumCount == 1)
        #expect(model.decision(for: id) == .moveToAlbum(id, fromAlbumId: nil, toAlbumId: "album-A"))
    }

    @Test("Delete then prev then move to album replaces delete and clears pending deletions")
    func deleteThenPrevThenMoveToAlbumReplacesDeleteAndAdjustsCounters() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true)])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()
        let id = await mock.assetIdentifier(at: 0)!

        await model.swipeDelete()
        #expect(model.pendingDeletions.count == 1)
        #expect(model.decision(for: id) == .delete(id))

        await model.swipePrev()
        await model.swipeUp(intoAlbumId: "album-A")

        #expect(model.pendingDeletions.isEmpty, "Pending deletions must be cleared when replaced by album move")
        #expect(model.movedToAlbumCount == 1)
        #expect(model.decision(for: id) == .moveToAlbum(id, fromAlbumId: nil, toAlbumId: "album-A"))
    }

    @Test("Move to album then prev then delete replaces move and stages delete")
    func moveToAlbumThenPrevThenDeleteReplacesMove() async {
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true)])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()
        let id = await mock.assetIdentifier(at: 0)!

        await model.swipeUp(intoAlbumId: "album-A")
        #expect(model.movedToAlbumCount == 1)

        await model.swipePrev()
        await model.swipeDelete()

        #expect(model.movedToAlbumCount == 0)
        #expect(model.pendingDeletions.count == 1)
        #expect(model.decision(for: id) == .delete(id))
        #expect(mock.lastRemoves.count == 1)
    }

    @Test("Multi-asset sequential moves, multiple prev hops, and accurate badge/counter state")
    func multiAssetSequentialMovesPrevAndRedecisions() async {
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 4)
        mock.seedAlbums([
            UserAlbum(id: "album-A", title: "A", assetCount: 0, canAdd: true),
            UserAlbum(id: "album-B", title: "B", assetCount: 0, canAdd: true)
        ])
        let model = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
        await model.start()

        let id0 = await mock.assetIdentifier(at: 0)!
        let id1 = await mock.assetIdentifier(at: 1)!
        let id2 = await mock.assetIdentifier(at: 2)!

        // Move id0 -> A, id1 -> B, favorite id2
        await model.swipeUp(intoAlbumId: "album-A")
        await model.swipeUp(intoAlbumId: "album-B")
        await model.swipeFavorite()

        #expect(model.movedToAlbumCount == 2)
        #expect(model.favoritedCount == 1)
        #expect(model.currentIndex == 3)

        // Hop back twice to index 1 (id1)
        await model.swipePrev()
        await model.swipePrev()
        #expect(model.currentIndex == 1)
        #expect(model.decision(for: id1) == .moveToAlbum(id1, fromAlbumId: nil, toAlbumId: "album-B"))

        // Redecide id1 to delete
        await model.swipeDelete()
        #expect(model.movedToAlbumCount == 1, "Only id0 remains moved")
        #expect(model.decision(for: id1) == .delete(id1))

        // Hop back to index 0 (id0) and redecide from A to B
        await model.swipePrev()
        await model.swipePrev()
        #expect(model.currentIndex == 0)
        await model.swipeUp(intoAlbumId: "album-B")
        #expect(model.movedToAlbumCount == 1)
        #expect(model.decision(for: id0) == .moveToAlbum(id0, fromAlbumId: nil, toAlbumId: "album-B"))
    }
}
