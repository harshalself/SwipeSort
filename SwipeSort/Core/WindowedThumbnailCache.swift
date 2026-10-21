import Foundation
import UIKit

/// Manages a sliding pre-cache window around the current swipe index.
///
/// Each `slide(to:total:)` call computes the set difference between the new and
/// old windows so `startCachingThumbnails` fires only for newly-entered indices
/// and `stopCachingThumbnails` fires only for indices that just left.
///
/// Why delta-only updates: `PHCachingImageManager` tracks outstanding requests
/// by the exact (targetSize, contentMode, options) triple. If start/stop pairs
/// are not 1-to-1 with byte-identical parameters the manager leaks cached memory
/// for the unmatched starts. Issuing redundant starts for already-cached indices
/// would require an equal number of extra stops to drain.
///
/// One instance lives per swipe session on `SwipeStackView`. `stopAll()` is
/// called on `onDisappear` so the cache is flushed when the user exits the deck.
///
/// Threading: `@MainActor`-isolated. `slide(to:total:)` is `async` but runs
/// exclusively on the main actor because the class carries `@MainActor`
/// isolation — the `Task { await thumbnailCache?.slide(...) }` created in
/// `SwipeStackView.onChange` stays on the main actor throughout.
@MainActor
final class WindowedThumbnailCache {

    private let library: PhotoLibraryProviding
    private let aheadOf: Int
    private let behind: Int
    private let targetSize: CGSize

    private var currentWindow: Range<Int> = 0..<0

    /// Creates a cache with the given lookahead and lookbehind window sizes.
    ///
    /// - Parameters:
    ///   - aheadOf: Number of indices to pre-cache ahead of the current position.
    ///   - behind: Number of indices to keep cached behind the current position (for undo).
    ///   - targetSize: Pixel dimensions passed to every caching request.
    /// - Parameters:
    ///   - aheadOf: Number of indices to pre-cache ahead of the current position.
    ///   - behind:  Number of indices to keep cached behind the current position
    ///              (supports fast undo without re-fetching thumbnails).
    ///   - targetSize: Pixel dimensions passed to every caching request.
    init(library: PhotoLibraryProviding,
         aheadOf: Int = 60,
         behind: Int = 15,
         targetSize: CGSize) {
        self.library = library
        self.aheadOf = aheadOf
        self.behind = behind
        self.targetSize = targetSize
    }

    /// Advances the cache window to be centred on `currentIndex`.
    ///
    /// Starts caching any newly-entered indices and stops caching indices that
    /// dropped out of the window. No-ops for indices already in the window.
    func slide(to currentIndex: Int, total: Int) async {
        // Cooperative cancellation: `SwipeStackView.onDisappear` cancels the
        // in-flight `slideTask`. Bail before touching `PHCachingImageManager`
        // so a stale slide can't reissue caching requests after `stopAll()`.
        guard !Task.isCancelled else { return }

        let lower = max(0, currentIndex - behind)
        let upper = min(total, currentIndex + aheadOf + 1)
        let newWindow = lower < upper ? (lower..<upper) : (0..<0)
        
        if currentWindow.contains(currentIndex) && newWindow == currentWindow {
            return
        }

        // Capture the old window and immediately update `currentWindow`.
        // Because this runs on the @MainActor, this synchronous update prevents
        // concurrent `slide` calls from computing overlapping deltas.
        let oldWindow = currentWindow
        currentWindow = newWindow

        let newSet = Set(newWindow)
        let oldSet = Set(oldWindow)
        let toStart = newSet.subtracting(oldSet).sorted()
        let toStop = oldSet.subtracting(newSet).sorted()

        if !toStart.isEmpty {
            let ids = await resolveIdentifiers(at: toStart)
            guard !Task.isCancelled else { return }
            if !ids.isEmpty {
                library.startCachingThumbnails(ids, targetSize: targetSize)
            }
        }
        if !toStop.isEmpty {
            let ids = await resolveIdentifiers(at: toStop)
            guard !Task.isCancelled else { return }
            if !ids.isEmpty {
                library.stopCachingThumbnails(ids, targetSize: targetSize)
            }
        }
    }

    /// Stops all outstanding caching requests and resets the window.
    ///
    /// Call on `onDisappear` to free cached memory when the swipe deck is exited.
    func stopAll() {
        library.stopCachingAllThumbnails()
        currentWindow = 0..<0
    }

    /// Converts absolute indices to `AssetIdentifier`s via one or more contiguous
    /// range fetches.
    ///
    /// Dense case (consecutive window slides): one contiguous fetch. Optimal —
    /// the caller's toStart/toStop sets are already dense runs.
    ///
    /// Sparse case (`span > indices.count × 2`): splits into contiguous runs and
    /// issues one fetch per run. Prevents a 20-index undo jump from fetching a
    /// 20-element span when only 5–7 identifiers are actually needed. Callers
    /// currently pass dense arrays via `slide`'s set-diffs, but the guard is
    /// defensive against future sparse inputs (e.g. multi-position undo/redo).
    private func resolveIdentifiers(at indices: [Int]) async -> [AssetIdentifier] {
        guard let first = indices.first, let last = indices.last else { return [] }

        let span = last - first + 1
        let isSparse = span > indices.count * 2

        if !isSparse {
            let batch = await library.identifiers(in: first..<(last + 1))
            var out: [AssetIdentifier] = []
            out.reserveCapacity(indices.count)
            for idx in indices {
                let offset = idx - first
                if offset >= 0, offset < batch.count {
                    out.append(batch[offset])
                }
            }
            return out
        }

        var runs: [[Int]] = []
        var currentRun: [Int] = [indices[0]]
        for i in 1..<indices.count {
            if indices[i] == indices[i - 1] + 1 {
                currentRun.append(indices[i])
            } else {
                runs.append(currentRun)
                currentRun = [indices[i]]
            }
        }
        runs.append(currentRun)

        var out: [AssetIdentifier] = []
        out.reserveCapacity(indices.count)
        for run in runs {
            guard let runFirst = run.first, let runLast = run.last else { continue }
            let batch = await library.identifiers(in: runFirst..<(runLast + 1))
            for idx in run {
                let offset = idx - runFirst
                if offset >= 0, offset < batch.count {
                    out.append(batch[offset])
                }
            }
        }
        return out
    }
}
