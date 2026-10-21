import Foundation
import Observation

/// Owns the per-view "total count + generation" state that drives the
/// index-driven grid.
///
/// `refresh(from:filter:)` re-reads `library.assetCount()` and bumps
/// `generation` only when the underlying fetch result actually changed
/// (or this is the first refresh). Bumping `generation` changes each
/// `AsyncThumbnailCell`'s `.task(id:)` key, forcing every visible cell to
/// re-resolve its identifier — the asset at any given index may have
/// changed after a library edit. Skipping the bump when nothing in our
/// fetch result moved preserves `PHCachingImageManager` reference counts
/// and avoids redundant thumbnail requests.
///
/// The controller intentionally does not fetch a range of identifiers: the
/// grid resolves them per-cell on demand. `MockPhotoLibrary.identifiersCallRanges`
/// remaining empty across a `refresh` on a 10 000-count mock is the observable
/// invariant guarding this.
@Observable
@MainActor
final class LoadCountController {
    private(set) var totalCount: Int = 0
    private(set) var hasIndexed: Bool = false
    private(set) var generation: Int = 0
    private(set) var authStatus: PhotoLibraryAuthorization = .notDetermined

    func refresh(from library: PhotoLibraryProviding, filter: SwipeFilter) async {
        var currentAuth = await library.currentAuthorization()
        if currentAuth == .notDetermined {
            currentAuth = await library.requestAuthorization()
        }
        authStatus = currentAuth
        // Ensure PhotoKit change notifications are wired up for grid-only users
        // who never open a swipe session. No-op if already registered or if
        // authorization was denied.
        PhotoLibraryChangePublisher.shared.registerIfAuthorized()
        await library.applyFilter(filter)
        let fetchChanged = await library.refreshFetchResult()
        totalCount = await library.assetCount()
        // Cold start must bump generation to unblock the initial render even
        // if the library reports "no change" (e.g. mock defaults).
        if fetchChanged || !hasIndexed {
            generation &+= 1
        }
        hasIndexed = true
    }

    /// Explicitly bumps the generation counter to force visible grid cells to refresh
    /// properties such as favorite status (`isFavorite`) when metadata changes without
    /// changing the asset count or order.
    func bumpGeneration() {
        generation &+= 1
    }
}
