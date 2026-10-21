import Foundation
import Observation

/// The physical direction of a completed drag gesture.
enum SwipeDirection: String, CaseIterable, Codable, Sendable, Hashable {
    case up, down, left, right
}

/// The recorded outcome for a single asset in a swipe session.
///
/// `.moveToAlbum` carries both source and destination album local identifiers
/// so the commit step can issue an atomic remove-then-add. `fromAlbumId` is
/// `nil` when the session was opened from All Photos (add-only move).
enum SwipeDecision: Sendable, Equatable {
    case keep(AssetIdentifier)
    case delete(AssetIdentifier)
    case moveToAlbum(AssetIdentifier, fromAlbumId: String?, toAlbumId: String)

    var identifier: AssetIdentifier {
        switch self {
        case .keep(let id), .delete(let id): return id
        case .moveToAlbum(let id, _, _): return id
        }
    }
}

/// In-memory ordered log of swipe decisions for the active session.
///
/// `@Observable` so SwiftUI badge counters re-render automatically on every
/// `record` / `undoLast` call. The queue is the authoritative source of
/// truth for `pendingDeletions`, `movedToAlbumCount`, and undo navigation.
///
/// Contract: `.moveToAlbum` entries live in `decisions` while undoable, and
/// are stripped by `removeCommitted()` after a successful commit. The
/// `movedToAlbumCount` counter persists across commits so the summary screen
/// can show the full session total regardless of how many commit cycles ran.
///
/// Threading: `@MainActor`-isolated (N2 fix). All production callers go through
/// `@MainActor SwipeSessionModel`. `DeletionQueueView` reads `decisions` from a
/// SwiftUI body, which also runs on the main actor. No callers need `await` to
/// call mutation methods.
@Observable
@MainActor
final class DecisionQueue {

    private(set) var decisions: [SwipeDecision] = []
    private var decisionsById: [AssetIdentifier: SwipeDecision] = [:]

    /// Running total of move-to-album swipes for the lifetime of this session.
    ///
    /// Incremented by `record(.moveToAlbum...)` and decremented by `undoLast()`
    /// when the popped decision is a `.moveToAlbum`. Never reset by
    /// `removeCommitted()` — it is the canonical session total for summary display.
    private(set) var movedToAlbumCount: Int = 0

    /// The set of asset identifiers that were kept via `swipeFavorite()`.
    ///
    /// Tracked separately from `decisions` so the summary screen can show a
    /// dedicated "Favorited" count that excludes plain-keep swipes (Finding 2 fix).
    private(set) var favoritedIds: Set<AssetIdentifier> = []

    /// The number of assets favorited during this session (via `swipeFavorite()`).
    var favoritedCount: Int { favoritedIds.count }

    /// Marks an asset as having been favorited via `swipeFavorite()`.
    ///
    /// Must be called immediately after `record(.keep(id))` for the same identifier.
    func markFavorited(_ id: AssetIdentifier) {
        favoritedIds.insert(id)
    }

    /// Appends a decision to the end of the queue.
    ///
    /// For `.moveToAlbum`, also increments `movedToAlbumCount` so the summary
    /// screen always reflects the full session total even after commits strip the
    /// entries from `decisions`.
    func record(_ decision: SwipeDecision) {
        decisions.append(decision)
        decisionsById[decision.identifier] = decision
        if case .moveToAlbum = decision {
            movedToAlbumCount += 1
        }
    }

    /// Removes and returns the most recent decision, or `nil` if the queue is empty.
    ///
    /// For `.moveToAlbum`, decrements `movedToAlbumCount` so the counter stays
    /// accurate while the user is still within the undo window.
    /// For `.keep`, removes the identifier from `favoritedIds` so the favorited
    /// count is consistent with the undo (Finding 2 fix).
    @discardableResult
    func undoLast() -> SwipeDecision? {
        guard let popped = decisions.popLast() else { return nil }
        decisionsById[popped.identifier] = nil
        switch popped {
        case .moveToAlbum:
            movedToAlbumCount = max(0, movedToAlbumCount - 1)
        case .keep(let id):
            favoritedIds.remove(id)
        case .delete:
            break
        }
        return popped
    }

    /// Returns the existing decision for a specific asset by identifier, if any.
    func decision(for id: AssetIdentifier) -> SwipeDecision? {
        decisionsById[id]
    }

    /// Removes the decision for a specific asset by identifier.
    ///
    /// Used when the user removes an individual photo from the deletion
    /// preview sheet. Returns the removed decision, or `nil` if no decision
    /// exists for `id`. Also maintains `movedToAlbumCount` and `favoritedIds`
    /// (Finding 3 fix: pre-remove before re-deciding must not corrupt counters).
    @discardableResult
    func removeDecision(for id: AssetIdentifier) -> SwipeDecision? {
        guard let idx = decisions.firstIndex(where: { $0.identifier == id }) else { return nil }
        let removed = decisions.remove(at: idx)
        decisionsById[id] = nil
        switch removed {
        case .moveToAlbum:
            movedToAlbumCount = max(0, movedToAlbumCount - 1)
        case .keep:
            favoritedIds.remove(id)
        case .delete:
            break
        }
        return removed
    }

    /// Drops all `.delete` and `.moveToAlbum` decisions after a successful commit.
    ///
    /// `.keep` entries are retained for the finished-summary display.
    /// `movedToAlbumCount` is intentionally NOT reset — it serves as the
    /// permanent session-total counter used by the summary screen.
    ///
    /// Why strip `.moveToAlbum`: moves execute immediately at swipe time and are
    /// never re-executed at commit. Retaining them after commit causes unbounded
    /// accumulation in long sessions and misleads any future code path that reads
    /// the decisions array to determine pending work (W3 fix).
    func removeCommitted() {
        decisions.removeAll { d in
            switch d {
            case .delete, .moveToAlbum: 
                decisionsById[d.identifier] = nil
                return true
            case .keep: 
                return false
            }
        }
    }
}
