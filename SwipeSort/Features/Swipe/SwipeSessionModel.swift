import Foundation
import Observation
import UIKit

/// The view model that drives the swipe deck.
///
/// Owns the fetch-cursor position (`currentIndex`), the currently displayed
/// thumbnails, the `DecisionQueue`, and the session lifecycle `Phase`.
/// All PhotoKit access is proxied through the injected `PhotoLibraryProviding`
/// so tests can substitute `MockPhotoLibrary`.
///
/// Ordering invariant: `advance()` increments `currentIndex` before calling
/// `loadCurrent()`. `undo()` walks backward from `min(currentIndex, totalCount-1)`
/// to find the popped identifier's true position.
///
/// Threading: `@MainActor`-isolated. Every `async` method must be called from
/// the main actor; mixing off-actor calls on `currentIndex` or `queue` would
/// violate the isolation guarantee the `@Observable` macro relies on.
@Observable
@MainActor
final class SwipeSessionModel {

    /// The lifecycle state of the swipe session.
    enum Phase: Equatable {
        case idle
        case requestingAuthorization
        case denied
        case loading
        case ready
        case committing
        case finished
    }

    private(set) var phase: Phase = .idle
    /// The thumbnail for the asset currently shown in the top card.
    private(set) var currentAssetId: AssetIdentifier?
    private(set) var nextAssetId: AssetIdentifier?
    private(set) var previousAssetId: AssetIdentifier?
    private(set) var currentThumbnail: AssetThumbnail?
    /// Pre-fetched thumbnail for the next asset, used to reduce latency on swipe.
    private(set) var nextThumbnail: AssetThumbnail?
    /// Pre-fetched thumbnail for the nearest undecided asset behind the cursor.
    private(set) var previousThumbnail: AssetThumbnail?
    private(set) var currentKind: MediaKind = .photo
    private(set) var currentIndex: Int = 0
    private(set) var totalCount: Int = 0

    /// The session's decision log. Exposed so `DeletionQueueView` can read
    /// pending decisions. Callers must not call mutation methods directly —
    /// use the swipe/undo/remove APIs on this model instead.
    let queue = DecisionQueue()

    private let library: PhotoLibraryProviding
    /// Late-configurable so `SwipeStackView` can recompute the pixel size once
    /// the view is attached to a screen (init-time reads of
    /// `UITraitCollection.current.displayScale` can return 1.0 pre-attachment).
    private var targetSize: CGSize

    /// Bumps on every `loadCurrent()` entry. Progress callbacks that outlive
    /// the fetch they were scheduled from are discarded so a late write cannot
    /// overwrite the next card's state (F4 fix, extended from grid to swipe deck).
    private var loadGeneration: Int = 0

    /// The album the session is running inside, or `nil` for All Photos.
    ///
    /// When `nil`, `.moveToAlbum` decisions record `fromAlbumId == nil`
    /// and the commit reduces to a plain add-to-destination.
    let sourceAlbumId: String?
    let initialIndex: Int
    let initialAssetId: AssetIdentifier?

    init(library: PhotoLibraryProviding,
         sourceAlbumId: String? = nil,
         initialIndex: Int = 0,
         initialAssetId: AssetIdentifier? = nil,
         targetSize: CGSize) {
        self.library = library
        self.sourceAlbumId = sourceAlbumId
        self.initialIndex = initialIndex
        self.initialAssetId = initialAssetId
        self.targetSize = targetSize
    }

    func start() async {
        await performAction {
            let auth = await self.library.currentAuthorization()
            let resolvedAuth: PhotoLibraryAuthorization
            if auth == .notDetermined {
                self.phase = .requestingAuthorization
                resolvedAuth = await self.library.requestAuthorization()
            } else {
                resolvedAuth = auth
            }

            switch resolvedAuth {
            case .authorized, .limited:
                PhotoLibraryChangePublisher.shared.register()
                await self.loadInitial()
            case .denied, .restricted, .notDetermined:
                self.phase = .denied
            }
        }
    }

    /// Updates the pixel target passed to subsequent thumbnail requests.
    /// Called from `SwipeStackView.task` after the view is on-screen so the
    /// display scale used to compute the target is the real one, not the
    /// pre-attachment default of 1.0.
    func configure(targetSize newSize: CGSize) {
        targetSize = newSize
    }

    /// Sets the Photos favourite flag on the current asset, records a `.keep`
    /// decision, and advances to the next asset.
    ///
    /// Also marks the asset in `favoritedIds` so the summary screen can show
    /// a dedicated Favorited count that excludes plain-keep swipes (Finding 2 fix).
    ///
    /// Calls `removeDecision(for:)` before recording to handle re-decision after
    /// swipePrev (Finding 3 fix).
    func swipeFavorite() async {
        await performAction {
            guard let id = self.currentAssetId else { return }
            await self.removeDecisionAndRevertSideEffects(for: id)
            self.queue.record(.keep(id))
            self.queue.markFavorited(id)
            Task { _ = await self.library.setFavorite(id, isFavorite: true) }
            await self.advance()
        }
    }

    /// Records a `.delete` decision for the current asset and advances.
    ///
    /// The deletion is not executed immediately; it is batched in the queue
    /// and submitted when the user confirms in `DeletionQueueView` or via
    /// `commitDecisions()`.
    ///
    /// Calls `removeDecisionAndRevertSideEffects(for:)` before recording to handle
    /// re-decision after `swipePrev`.
    func swipeDelete() async {
        await performAction {
            guard let id = self.currentAssetId else { return }
            await self.removeDecisionAndRevertSideEffects(for: id)
            self.queue.record(.delete(id))
            await self.advance()
        }
    }

    /// Executes an immediate album move and records a `.moveToAlbum` decision.
    ///
    /// The move fires synchronously at swipe time (not deferred to commit).
    /// The source album is captured from `sourceAlbumId` at session-start time
    /// so a mid-session parent-view change cannot affect where assets are moved from.
    ///
    /// Why: album moves require no user confirmation step, unlike deletions.
    /// Recording the decision in the queue allows the summary view to display
    /// a moved-count and lets `undo()` reverse the move.
    ///
    /// Calls `removeDecisionAndRevertSideEffects(for:)` before recording so that
    /// redeciding an asset after `swipePrev` cleanly replaces the previous action and
    /// reverts any prior move side-effect rather than duplicating entries or inflating counts.
    func swipeUp(intoAlbumId destinationAlbumId: String) async {
        await performAction {
            guard destinationAlbumId != self.sourceAlbumId else { return }
            guard let id = self.currentAssetId else { return }
            await self.removeDecisionAndRevertSideEffects(for: id)
            let sourceId = self.sourceAlbumId
            self.queue.record(.moveToAlbum(id, fromAlbumId: sourceId, toAlbumId: destinationAlbumId))
            Task {
                _ = await self.library.moveAssets([id], fromAlbumId: sourceId, toAlbumId: destinationAlbumId)
            }
            await self.advance()
        }
    }

    /// The number of assets favorited via `swipeFavorite()` during this session.
    ///
    /// Backed by `DecisionQueue.favoritedIds` so it is accurate after undo
    /// operations. Does not include plain-keep swipes (Finding 2 fix).
    var favoritedCount: Int { queue.favoritedCount }

    /// Advances to the next asset without recording any decision.
    ///
    /// If `currentIndex` is already at the last asset (`totalCount - 1`), this is a no-op so that
    /// skipping (`next`) does not transition to `.finished` summary view.
    func swipeNext() async {
        await performAction {
            guard self.currentIndex < self.totalCount - 1 else { return }
            await self.advance()
        }
    }

    /// Navigates backward to the previous asset, regardless of whether it already
    /// has a decision in the queue.
    ///
    /// Mirrors standard gallery "back" semantics: pressing "prev" always moves to
    /// `currentIndex - 1`. If `currentIndex` is 0 this is a no-op.
    func swipePrev() async {
        await performAction {
            if let prevId = self.previousAssetId,
               let exactIndex = await self.library.indexOfAsset(withIdentifier: prevId) {
                self.currentIndex = exactIndex
            } else {
                guard self.currentIndex > 0 else { return }
                self.currentIndex -= 1
            }
            self.phase = .ready
            await self.syncIdentifiers()
            self.loadGeneration &+= 1
            Task { await self.loadCurrent() }
        }
    }

    /// Maps a physical swipe direction to a semantic action.
    func swipe(_ direction: SwipeDirection) async {
        switch direction {
        case .up:    await swipeDelete()
        case .down:  await swipeFavorite()
        case .left:  await swipeNext()
        case .right: await swipePrev()
        }
    }

    /// Pops the most recent decision, reverses any library side-effect, and returns
    /// to the position of that asset.
    ///
    /// For `.moveToAlbum` decisions the move is reversed: if the asset came from a
    /// source album it is moved back; if it came from All Photos it is removed from
    /// the destination album.
    ///
    /// Navigation: `currentIndex - 1` would be wrong when `advance()` previously
    /// skipped decided assets. The backward scan finds the popped identifier's true
    /// fetch-result position.
    ///
    /// Fallback: if the popped identifier is not found (asset deleted externally or
    /// removed by iCloud sync), steps back by 1 rather than jumping to index 0 (W5 fix).
    @discardableResult
    func undo() async -> SwipeDecision? {
        await performAction {
            guard let popped = self.queue.undoLast() else { return nil }
            await self.revertSideEffects(for: popped)

            let searchStart = min(self.currentIndex, max(0, self.totalCount - 1))
            var target: Int? = nil
            var i = searchStart
            while i >= 0 {
                if let id = await self.library.assetIdentifier(at: i), id == popped.identifier {
                    target = i
                    break
                }
                i -= 1
            }
            if let found = target {
                self.currentIndex = found
            } else {
                self.currentIndex = max(0, self.currentIndex - 1)
            }
            self.phase = .ready
            await self.syncIdentifiers()
            self.loadGeneration &+= 1
            Task { await self.loadCurrent() }
            return popped
        }
    }

    /// The ordered list of assets queued for deletion, de-duplicated.
    ///
    /// Only `.delete` decisions appear here; `.keep` and `.moveToAlbum` are excluded.
    var pendingDeletions: [AssetIdentifier] {
        var seen = Set<AssetIdentifier>()
        return queue.decisions.compactMap { decision in
            if case .delete(let id) = decision, seen.insert(id).inserted {
                return id
            }
            return nil
        }
    }

    /// Removes any existing decision for `id` from the queue and reverts any physical
    /// side-effect (e.g., reversing a prior `.moveToAlbum` in the library) so that
    /// re-deciding an asset after `swipePrev()` cleanly replaces the previous action without duplicates.
    @discardableResult
    func removeDecisionAndRevertSideEffects(for id: AssetIdentifier) async -> SwipeDecision? {
        guard let removed = self.queue.removeDecision(for: id) else { return nil }
        await self.revertSideEffects(for: removed)
        return removed
    }

    private func revertSideEffects(for decision: SwipeDecision) async {
        if case .moveToAlbum(let id, let fromAlbumId, let toAlbumId) = decision {
            if let from = fromAlbumId {
                _ = await self.library.moveAssets([id], fromAlbumId: toAlbumId, toAlbumId: from)
            } else {
                if !DryRunMode.isEnabled {
                    let removeResult = await self.library.removeAssetsFromAlbum([id], albumId: toAlbumId)
                    if case .failed(let reason) = removeResult {
                        print("[SwipeSort] revert removeAssetsFromAlbum failed: \(reason)")
                    }
                }
            }
        }
    }

    /// The number of assets moved to an album during this session.
    ///
    /// Reads `DecisionQueue.movedToAlbumCount` — a dedicated counter that
    /// persists across commit cycles regardless of whether `.moveToAlbum` entries
    /// have been stripped from `decisions` by `removeCommitted()`. This is the
    /// canonical summary-screen total (W1/W3 fix).
    var movedToAlbumCount: Int {
        queue.movedToAlbumCount
    }

    /// Returns the existing decision for a specific asset by identifier, if any.
    func decision(for id: AssetIdentifier) -> SwipeDecision? {
        queue.decision(for: id)
    }

    /// Removes a specific asset from the deletion queue without undoing later decisions.
    ///
    /// Used by `DeletionQueueView` when the user de-queues an individual photo.
    func removeFromDeletionQueue(_ id: AssetIdentifier) {
        queue.removeDecision(for: id)
    }

    /// Submits all pending deletions to PhotoKit and transitions the session to `.finished`
    /// on success. On `.cancelledByUser` or `.failed`, reverts `phase` to `.ready` so the
    /// user can retry from the swipe deck without restarting the session.
    ///
    /// Album moves are not re-executed here — they fired immediately in `swipeUp` (fire-and-
    /// forget contract). The early exit on an empty `deleteIds` is correct under this contract:
    /// if there are no pending deletions, all side-effects have already executed, and
    /// transitioning to `.finished` is valid. This invariant holds as long as no deferred move
    /// work is ever introduced; if moves become deferred in a future phase, this guard must
    /// be widened to also check pending move work before exiting early.
    ///
    /// Invariant: `phase = .finished` is only ever set on `.success`. Any other result
    /// leaves the queue intact and returns the deck to an interactive state.
    func commitDecisions() async -> CommitResult {
        await performAction {
            let deleteIds = self.pendingDeletions
            guard !deleteIds.isEmpty else {
                self.phase = .finished
                return .success(affectedCount: 0)
            }

            self.phase = .committing
            let deleteResult = await self.library.commitDeletions(deleteIds)

            switch deleteResult {
            case .success:
                self.queue.removeCommitted()
                self.phase = .finished
            case .cancelledByUser, .failed:
                self.phase = .ready
            }
            return deleteResult
        }
    }

    /// Resyncs the session state with the underlying photo library.
    /// 
    /// Called when the library notifies us of external changes or when asynchronous
    /// side-effects (like moveAssets) resolve. This prevents the `currentIndex` from
    /// drifting out of bounds if assets are removed from the current fetch result.
    func refreshLibraryState() async {
        await performAction {
            self.totalCount = await self.library.assetCount()
            
            if self.totalCount == 0 {
                self.phase = .finished
                self.currentThumbnail = nil
                self.nextThumbnail = nil
                self.previousThumbnail = nil
                return
            }
            
            if let id = self.currentThumbnail?.identifier,
               let newIndex = await self.library.indexOfAsset(withIdentifier: id) {
                self.currentIndex = newIndex
            } else {
                // If the current asset was deleted entirely or not found, clamp the index
                self.currentIndex = min(self.currentIndex, max(0, self.totalCount - 1))
            }
            await self.syncIdentifiers()
            self.loadGeneration &+= 1
            Task { await self.loadCurrent() }
        }
    }

    // MARK: - Private

    private var actionTask: Task<Any, Never>?

    @discardableResult
    private func performAction<R: Sendable>(_ action: @escaping @MainActor () async -> R) async -> R {
        let previous = actionTask
        let task = Task<Any, Never> { @MainActor in
            if let previous {
                _ = await previous.value
            }
            return await action()
        }
        actionTask = task
        let result = await task.value
        if actionTask == task {
            actionTask = nil
        }
        return result as! R
    }

    /// Fetches the total asset count and positions the cursor at the initial index.
    private func syncIdentifiers() async {
        let total = self.totalCount
        let idx = self.currentIndex
        self.currentAssetId = await library.assetIdentifier(at: idx)
        self.nextAssetId = (idx + 1 < total) ? await library.assetIdentifier(at: idx + 1) : nil
        let prevIndex = idx > 0 ? idx - 1 : nil
        self.previousAssetId = prevIndex != nil ? await library.assetIdentifier(at: prevIndex!) : nil
    }

    private func loadInitial() async {
        phase = .loading
        totalCount = await library.assetCount()

        if totalCount == 0 {
            currentIndex = 0
            phase = .finished
            currentThumbnail = nil
            nextThumbnail = nil
            previousThumbnail = nil
            return
        }

        if let initialAssetId, let exactIndex = await library.indexOfAsset(withIdentifier: initialAssetId) {
            currentIndex = exactIndex
        } else {
            currentIndex = min(initialIndex, max(0, totalCount - 1))
        }
        await syncIdentifiers()
        loadGeneration &+= 1
        await loadCurrent()
        phase = .ready
    }

    /// Increments `currentIndex` and loads the next asset, or transitions to `.finished`.
    private func advance() async {
        if let nextId = nextAssetId,
           let exactIndex = await library.indexOfAsset(withIdentifier: nextId) {
            currentIndex = exactIndex
        } else {
            currentIndex += 1
        }

        if currentIndex >= totalCount {
            loadGeneration &+= 1 // Invalidate any in-flight detached image fetches
            phase = .finished
            currentAssetId = nil
            nextAssetId = nil
            previousAssetId = nil
            currentThumbnail = nil
            nextThumbnail = nil
            previousThumbnail = nil
            return
        }
        await syncIdentifiers()
        loadGeneration &+= 1
        Task { await loadCurrent() }
    }

    /// Fetches the thumbnail and media kind for the current index, plus
    /// look-ahead (next) and look-behind (previous) thumbnails concurrently.
    private func loadCurrent() async {
        let generation = loadGeneration

        guard let id = currentAssetId else {
            currentThumbnail = nil
            nextThumbnail = nil
            previousThumbnail = nil
            currentKind = .photo
            return
        }
        let nextId = nextAssetId
        let prevId = previousAssetId

        async let currentThumbTask: AssetThumbnail? = library.thumbnail(for: id, targetSize: targetSize)
        async let currentKindTask = library.mediaKind(for: id)
        async let nextThumbTask: AssetThumbnail? = nextId != nil
            ? library.thumbnail(for: nextId!, targetSize: targetSize)
            : nil
        async let prevThumbTask: AssetThumbnail? = prevId != nil
            ? library.thumbnail(for: prevId!, targetSize: targetSize)
            : nil

        let cThumb = await currentThumbTask
        let cKind = await currentKindTask
        let nThumb = await nextThumbTask
        let pThumb = await prevThumbTask

        guard generation == loadGeneration else { return }

        currentThumbnail = cThumb
        currentKind = cKind
        nextThumbnail = nThumb
        previousThumbnail = pThumb
    }
}
