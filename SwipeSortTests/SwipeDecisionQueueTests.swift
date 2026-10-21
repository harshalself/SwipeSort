import Testing
import Foundation
import UIKit
@testable import SwipeSort

@Suite("DecisionQueue")
@MainActor
struct SwipeDecisionQueueTests {

    private func id(_ n: Int) -> AssetIdentifier { AssetIdentifier("asset-\(n)") }

    private func deleteCount(_ q: DecisionQueue) -> Int {
        q.decisions.reduce(0) { acc, d in
            if case .delete = d { return acc + 1 }
            return acc
        }
    }

    private func keepCount(_ q: DecisionQueue) -> Int {
        q.decisions.reduce(0) { acc, d in
            if case .keep = d { return acc + 1 }
            return acc
        }
    }

    @Test("starts empty")
    func startsEmpty() {
        let q = DecisionQueue()
        #expect(q.decisions.isEmpty)
        #expect(deleteCount(q) == 0)
        #expect(keepCount(q) == 0)
    }

    @Test("records decisions in order")
    func recordsInOrder() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.keep(id(3)))
        #expect(q.decisions.count == 3)
        #expect(q.decisions[0] == .keep(id(1)))
        #expect(q.decisions[1] == .delete(id(2)))
        #expect(q.decisions[2] == .keep(id(3)))
    }

    @Test("counts split by decision kind")
    func countsSplit() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.delete(id(3)))
        #expect(keepCount(q) == 1)
        #expect(deleteCount(q) == 2)
    }

    @Test("undoLast pops most recent and returns it")
    func undoLastPops() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        let popped = q.undoLast()
        #expect(popped == .delete(id(2)))
        #expect(q.decisions.count == 1)
        #expect(q.decisions[0] == .keep(id(1)))
    }

    @Test("undoLast on empty queue returns nil")
    func undoLastEmpty() {
        let q = DecisionQueue()
        let popped = q.undoLast()
        #expect(popped == nil)
    }

    @Test("decision(for:) returns the correct decision using O(1) dictionary lookup")
    func decisionForId() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
        
        #expect(q.decision(for: id(1)) == .keep(id(1)))
        #expect(q.decision(for: id(2)) == .delete(id(2)))
        #expect(q.decision(for: id(3)) == .moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
        #expect(q.decision(for: id(99)) == nil)
        
        q.undoLast()
        #expect(q.decision(for: id(3)) == nil)
        
        q.removeDecision(for: id(2))
        #expect(q.decision(for: id(2)) == nil)
    }

    @Test("removeDecision removes specific asset identifier and returns decision")
    func removeDecisionEdgeCases() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.delete(id(3)))

        // Non-existent ID returns nil
        #expect(q.removeDecision(for: id(99)) == nil)
        #expect(q.decisions.count == 3)

        // Removing middle ID works cleanly
        let removed = q.removeDecision(for: id(2))
        #expect(removed == .delete(id(2)))
        #expect(q.decisions.count == 2)
        #expect(deleteCount(q) == 1)
    }

    @Test("removeCommitted drops delete and moveToAlbum decisions while preserving keep decisions")
    func removeCommittedEdgeCases() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
        q.record(.keep(id(4)))

        q.removeCommitted()
        // After W3 fix: only .keep entries survive removeCommitted().
        #expect(q.decisions.count == 2)
        #expect(q.decisions[0] == .keep(id(1)))
        #expect(q.decisions[1] == .keep(id(4)))
        #expect(keepCount(q) == 2)
        #expect(deleteCount(q) == 0)
        // movedToAlbumCount persists for summary display.
        #expect(q.movedToAlbumCount == 1)
    }

    @Test("movedToAlbumCount increments when moveToAlbum is recorded and persists after removeCommitted")
    func movedToAlbumCountPersistsAfterCommit() {
        let q = DecisionQueue()
        let albumId = "album-X"
        q.record(.moveToAlbum(id(1), fromAlbumId: nil, toAlbumId: albumId))
        q.record(.moveToAlbum(id(2), fromAlbumId: "src-album", toAlbumId: albumId))
        q.record(.delete(id(3)))
        #expect(q.movedToAlbumCount == 2)

        q.removeCommitted()
        // delete and moveToAlbum entries are stripped from decisions array
        #expect(q.decisions.isEmpty == false ? q.decisions.allSatisfy({ if case .keep = $0 { return true }; return false }) : true)
        // but movedToAlbumCount remains for summary display
        #expect(q.movedToAlbumCount == 2)
    }

    @Test("removeCommitted strips both delete and moveToAlbum entries, keeps only keep decisions")
    func removeCommittedStripsMovesAndDeletes() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.record(.delete(id(2)))
        q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "alb-A"))
        q.record(.keep(id(4)))
        q.record(.moveToAlbum(id(5), fromAlbumId: "src", toAlbumId: "alb-B"))

        q.removeCommitted()
        #expect(q.decisions.count == 2)
        #expect(q.decisions[0] == .keep(id(1)))
        #expect(q.decisions[1] == .keep(id(4)))
        #expect(q.movedToAlbumCount == 2)
        #expect(deleteCount(q) == 0)
    }

    // MARK: - Finding 3 regression: removeDecision counter accounting

    @Test("removeDecision on a .moveToAlbum decision decrements movedToAlbumCount")
    func removeDecisionMoveToAlbumDecrementsCounter() {
        let q = DecisionQueue()
        q.record(.moveToAlbum(id(1), fromAlbumId: nil, toAlbumId: "alb-A"))
        q.record(.moveToAlbum(id(2), fromAlbumId: "src", toAlbumId: "alb-A"))
        #expect(q.movedToAlbumCount == 2)

        let removed = q.removeDecision(for: id(1))
        #expect(removed == .moveToAlbum(id(1), fromAlbumId: nil, toAlbumId: "alb-A"))
        // Counter must reflect the removal.
        #expect(q.movedToAlbumCount == 1)
    }

    @Test("removeDecision on a favorited .keep decision removes identifier from favoritedIds")
    func removeDecisionFavoritedKeepClearsFavoritedIds() {
        let q = DecisionQueue()
        q.record(.keep(id(1)))
        q.markFavorited(id(1))
        #expect(q.favoritedCount == 1)

        q.removeDecision(for: id(1))
        #expect(q.favoritedCount == 0)
        #expect(q.decisions.isEmpty)
    }

    @Test("undoLast on moveToAlbum still works after movedToAlbumCount is introduced")
    func undoLastMoveToAlbumStillWorks() {
        let q = DecisionQueue()
        q.record(.moveToAlbum(id(10), fromAlbumId: nil, toAlbumId: "alb-Z"))
        #expect(q.movedToAlbumCount == 1)
        let popped = q.undoLast()
        #expect(popped == .moveToAlbum(id(10), fromAlbumId: nil, toAlbumId: "alb-Z"))
        // Undo decrements the counter so summary accurately reflects the current state.
        #expect(q.movedToAlbumCount == 0)
        #expect(q.decisions.isEmpty)
    }

    @Test("DecisionQueue mutation methods are callable synchronously from @MainActor context")
    @MainActor
    func decisionQueueCallableOnMainActor() {
        // This test is a compile-time + runtime isolation pin. It verifies:
        // 1. All DecisionQueue mutation methods are callable without `await` from a @MainActor context.
        // 2. Thread.isMainThread is true at the call site, confirming main-actor execution.
        let q = DecisionQueue()
        #expect(Thread.isMainThread, "DecisionQueue must be accessed on the main thread")
        q.record(.keep(AssetIdentifier("iso-test-1")))
        q.record(.delete(AssetIdentifier("iso-test-2")))
        q.record(.moveToAlbum(AssetIdentifier("iso-test-3"), fromAlbumId: nil, toAlbumId: "alb-iso"))
        #expect(q.decisions.count == 3)
        #expect(q.movedToAlbumCount == 1)
        q.markFavorited(AssetIdentifier("iso-test-1"))
        #expect(q.favoritedCount == 1)
        let popped = q.undoLast()
        #expect(popped == .moveToAlbum(AssetIdentifier("iso-test-3"), fromAlbumId: nil, toAlbumId: "alb-iso"))
        #expect(q.movedToAlbumCount == 0)
        q.removeCommitted()
        // After removeCommitted() strips .delete entries, only .keep("iso-test-1") remains.
        #expect(q.decisions.count == 1)
        #expect(keepCount(q) == 1)
        #expect(deleteCount(q) == 0)
    }
}
