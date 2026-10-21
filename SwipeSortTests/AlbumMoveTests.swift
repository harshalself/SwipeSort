import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("Album move — swipeUp + commit", .serialized)
struct AlbumMoveTests {

    private let targetSize = CGSize(width: 1, height: 1)

    @Test("swipeUp from All Photos records .moveToAlbum with nil source")
    func swipeUpFromAllPhotos() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])

        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: targetSize
        )
        await m.start()
        await m.swipeUp(intoAlbumId: "fam")

        #expect(m.queue.decisions.count == 1)
        if case .moveToAlbum(_, let from, let to) = m.queue.decisions[0] {
            #expect(from == nil)
            #expect(to == "fam")
        } else {
            Issue.record("expected .moveToAlbum")
        }
    }

    @Test("swipeUp from a specific source album records both source and destination")
    func swipeUpFromAlbum() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([
            UserAlbum(id: "src", title: "Inbox", assetCount: 2, canAdd: true),
            UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true),
        ])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: "src", targetSize: targetSize
        )
        await m.start()
        await m.swipeUp(intoAlbumId: "fam")

        if case .moveToAlbum(_, let from, let to) = m.queue.decisions[0] {
            #expect(from == "src")
            #expect(to == "fam")
        } else {
            Issue.record("expected .moveToAlbum")
        }
    }

    @Test("swipeUp(intoAlbumId:) moves asset immediately")
    func immediateAlbumMove() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 4)
        mock.seedAlbums([
            UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true),
            UserAlbum(id: "trips", title: "Trips", assetCount: 0, canAdd: true),
        ])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: targetSize
        )
        await m.start()
        await m.swipeUp(intoAlbumId: "fam")   // 0 -> fam
        await m.swipeUp(intoAlbumId: "trips") // 1 -> trips
        await m.swipeUp(intoAlbumId: "fam")   // 2 -> fam

        #expect(mock.lastMoves.count == 3)
        #expect(mock.lastMoves[0].to == "fam")
        #expect(mock.lastMoves[1].to == "trips")
        #expect(mock.lastMoves[2].to == "fam")
        #expect(m.movedToAlbumCount == 3)
    }

    @Test("commitDecisions runs deletions only when moves were executed immediately")
    func commitMovesAndDeletes() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: targetSize
        )
        await m.start()
        await m.swipeDelete()                  // 0 -> delete
        await m.swipeUp(intoAlbumId: "fam")    // 1 -> fam immediately moved
        await m.swipeFavorite()                // 2 -> keep

        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].to == "fam")

        let result = await m.commitDecisions()
        #expect(result == .success(affectedCount: 1))
        #expect(mock.lastCommittedDeletions.count == 1)

        #expect(m.pendingDeletions.isEmpty)
        #expect(m.movedToAlbumCount == 1)
    }

    @Test("commitDecisions returns empty success when only immediate moves occurred")
    func commitOnlyMoves() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: targetSize
        )
        await m.start()
        await m.swipeUp(intoAlbumId: "fam")
        await m.swipeUp(intoAlbumId: "fam")

        #expect(mock.lastMoves.count == 2)
        let result = await m.commitDecisions()
        #expect(result == .success(affectedCount: 0))
        #expect(mock.lastCommittedDeletions.isEmpty)
        #expect(m.movedToAlbumCount == 2)
    }

    @Test("cancelled deletion aborts deletion commit while immediate moves remain intact")
    func cancelAbortsCommit() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])
        mock.nextCommitResult = .cancelledByUser
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: targetSize
        )
        await m.start()
        await m.swipeDelete()
        await m.swipeUp(intoAlbumId: "fam")

        let result = await m.commitDecisions()
        #expect(result == .cancelledByUser)
        #expect(mock.lastMoves.count == 1)
        #expect(m.pendingDeletions.count == 1)
        #expect(m.movedToAlbumCount == 1)
    }

    @Test("multi-select moveAssets batch moves selected IDs cleanly")
    func multiSelectMoveBatchToDestinationAlbum() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])

        let selectedIds = [AssetIdentifier("mock-asset-0"), AssetIdentifier("mock-asset-2")]
        let result = await mock.moveAssets(selectedIds, fromAlbumId: nil, toAlbumId: "fam")

        #expect(result == .success(affectedCount: 2))
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].ids == selectedIds)
        #expect(mock.lastMoves[0].to == "fam")
    }

    @Test("createUserAlbum creates new destination album and accepts asset moves")
    func createNewAlbumAndMoveBatch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let created = await mock.createUserAlbum(title: "Vacation")

        #expect(created != nil)
        #expect(created?.title == "Vacation")

        let ids = [AssetIdentifier("mock-asset-1")]
        let moveRes = await mock.moveAssets(ids, fromAlbumId: nil, toAlbumId: created!.id)
        #expect(moveRes == .success(affectedCount: 1))
    }

    @Test("undo of moveToAlbum from nil source records the remove call even when it fails")
    func undoMoveFromNilSourceHandlesRemoveFailure() async {
        // PRODUCTION GAP: SwipeSessionModel.undo() at SwipeSessionModel.swift:282–286
        // logs the .failed result but does not roll back the popped decision or surface
        // an error to the caller. This test pins the CURRENT contract — the queue is
        // emptied by undoLast() regardless of whether the physical remove succeeds.
        // A future phase should route the failure through a session-level warning.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])

        // Ensure dry-run is OFF for this test: undo() skips the remove entirely in
        // dry-run mode (SwipeSessionModel.swift:281), which would bypass the very
        // path this test is trying to exercise.
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(m.queue.decisions.count == 1)

        // Script the removeAssetsFromAlbum call to fail.
        mock.nextRemoveResult = .failed(reason: "smart album cannot removeContent")

        // Perform the undo — model logs the failure and continues.
        let undone = await m.undo()

        // The .moveToAlbum decision was popped from the queue (undoLast fires unconditionally).
        #expect(m.queue.decisions.isEmpty)
        if case .moveToAlbum(let id, _, _)? = undone {
            #expect(id == firstId)
        } else {
            Issue.record("expected the popped decision to be .moveToAlbum")
        }
        // The remove call was actually attempted (mock recorded it) — this pins the
        // undo path against a refactor that would silently skip the remove.
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "fam")
        #expect(mock.lastRemoves[0].ids == [firstId])
        // Phase transitions cleanly regardless of the remove result.
        #expect(m.phase == .ready)
    }

    @Test("undo of moveToAlbum from nil source calls removeAssetsFromAlbum on the destination")
    func undoMoveFromNilSourceCallsRemove() async {
        // Dry-run must be OFF for the remove path to execute (SwipeSessionModel.swift:281).
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastRemoves.isEmpty)

        await m.undo()

        // Undo must have called removeAssetsFromAlbum on "fam" for firstId.
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "fam")
        #expect(mock.lastRemoves[0].ids == [firstId])
        // The reversed move path (moveAssets) must NOT have fired.
        #expect(mock.lastMoves.count == 1, "no reversed moveAssets call for nil-source undo")
        #expect(m.queue.decisions.isEmpty)
    }

    @Test("undo of moveToAlbum from a source album calls moveAssets reversed (dest → source)")
    func undoMoveFromSourceCallsReversedMove() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([
            UserAlbum(id: "src", title: "Inbox",  assetCount: 3, canAdd: true),
            UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)
        ])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: "src", targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].from == "src")
        #expect(mock.lastMoves[0].to == "fam")

        await m.undo()

        // Undo must have appended a REVERSED moveAssets call: from "fam" back to "src".
        #expect(mock.lastMoves.count == 2)
        #expect(mock.lastMoves[1].from == "fam")
        #expect(mock.lastMoves[1].to   == "src")
        #expect(mock.lastMoves[1].ids  == [firstId])
        // No remove call should have fired for the non-nil-source path.
        #expect(mock.lastRemoves.isEmpty)
        #expect(m.queue.decisions.isEmpty)
    }
}
