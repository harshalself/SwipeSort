import Foundation
import UIKit
import AVFoundation
import Photos
import PhotosUI

/// A stable handle for a `PHAsset` identified by its `localIdentifier`.
///
/// Wrapping the raw string prevents callers from accidentally passing an
/// arbitrary string where a PhotoKit identifier is expected.
struct AssetIdentifier: Hashable, Sendable, Identifiable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
}

/// A rendered thumbnail with progressive-delivery metadata.
///
/// `isDegraded` is `true` when PhotoKit delivered a fast-path low-resolution
/// image and a higher-quality version is still in flight (`.opportunistic`
/// delivery mode). Callers should display the image immediately and replace
/// it when a non-degraded result arrives.
struct AssetThumbnail: Sendable {
    let identifier: AssetIdentifier
    let image: UIImage
    let isDegraded: Bool
}

/// Consolidated metadata for a single asset, avoiding multiple PhotoKit round-trips.
struct AssetMetadata: Sendable {
    let id: AssetIdentifier
    let mediaKind: MediaKind
    let isFavorite: Bool
}

/// Mirrors `PHAuthorizationStatus` without the PhotoKit import dependency.
///
/// Decoupled so test targets can reason about authorization states without
/// linking Photos.framework.
enum PhotoLibraryAuthorization: Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized
}

/// Outcome of a batch deletion or album-move commit operation.
enum CommitResult: Sendable, Equatable {
    case success(affectedCount: Int)
    case cancelledByUser
    case failed(reason: String)
}

/// The media kind behind an `AssetIdentifier`.
///
/// Drives card-view dispatch: photos use a static `Image`, videos get an
/// `AVPlayer` from `VideoPlayerPool`, and Live Photos get a
/// `PHLivePhotoView` with a tap-to-play hint.
enum MediaKind: Sendable, Equatable {
    case photo
    case livePhoto
    case video(durationSeconds: Double)
}

/// Opaque cancel token for an in-flight video request.
///
/// `PhotoKitLibrary` returns a real handle backed by `PHImageRequestID`; the
/// `MockPhotoLibrary` and the default protocol extension return `nil`.
/// Callers should call `cancel()` when the request's result is no longer
/// needed to release iCloud bandwidth — even after the initial `AVPlayerItem`
/// arrives, PhotoKit may continue downloading a higher-quality replacement
/// under `.automatic` delivery mode.
protocol VideoRequestHandle: Sendable {
    func cancel()
}

// MARK: - Sub-protocols

/// Read-only access to the photo library: authorization, fetch cursor, asset
/// enumeration, thumbnails, media classification, album listing, filter/scoping,
/// and fetch-result refresh.
///
/// Threading: concrete implementations (`PhotoKitLibrary`, `MockPhotoLibrary`)
/// are `@MainActor`-isolated. All callers must be `@MainActor`-isolated or cross
/// the actor boundary with `await` for the `async` requirements. The synchronous
/// requirements must be called from a `@MainActor` context.
@MainActor
protocol PhotoLibraryReadProviding: Sendable {
    func currentAuthorization() async -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    func assetCount() async -> Int
    func assetIdentifier(at index: Int) async -> AssetIdentifier?
    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int?
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail?
    func thumbnailStream(for identifier: AssetIdentifier, targetSize: CGSize) -> AsyncStream<AssetThumbnail>

    /// Fast-path metadata lookup using the expected index in the current fetch result.
    /// Returns all per-asset metadata in a single O(1) PHFetchResult array access,
    /// avoiding 2–3 separate fetchAssets(withLocalIdentifiers:) database round-trips per cell.
    func assetMetadata(at index: Int, expectedId: AssetIdentifier) async -> AssetMetadata?

    func userAlbums() async -> [UserAlbum]
    func mediaKind(for id: AssetIdentifier) async -> MediaKind
    func identifiers(in range: Range<Int>) async -> [AssetIdentifier]

    /// Reads the Photos native favourite flag on a single asset.
    ///
    /// Returns `false` for unknown identifiers and for assets the caller has no
    /// read access to; distinguishing "not favourited" from "unknown" isn't
    /// useful to menu code, which only needs a starting toggle state.
    func isFavorite(for id: AssetIdentifier) async -> Bool

    /// Applies a load-time filter and invalidates the cached fetch cursor.
    ///
    /// Must be called before `SwipeSessionModel.start()` or any count /
    /// identifier lookup. Changing the filter mid-session produces an
    /// inconsistent index space — the session must be restarted.
    func applyFilter(_ filter: SwipeFilter) async

    /// Returns a new library instance scoped to assets within the given album.
    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding

    /// Refreshes the cached `PHFetchResult` and reports whether it changed.
    ///
    /// Returns `true` when the caller should treat downstream state as stale
    /// (cold start, or a `PHChange` since the last refresh actually touched
    /// this library's fetch result). Returns `false` when the fetch cursor
    /// is unchanged so callers can skip generation-bump work on the SwiftUI side.
    func refreshFetchResult() async -> Bool
}

/// Pre-caching and rich-media delivery (video, Live Photo) operations.
///
/// Threading: `@MainActor`-isolated on concrete implementations.
/// `startCachingThumbnails` / `stopCachingThumbnails` / `stopCachingAllThumbnails`
/// are synchronous and must be called from a `@MainActor` context.
@MainActor
protocol PhotoLibraryCacheProviding: Sendable {
    /// Starts pre-caching thumbnails for the given identifiers at `targetSize`.
    ///
    /// Must be matched by a `stopCachingThumbnails` call with the identical
    /// `targetSize`. `PHCachingImageManager` reference-counts start/stop pairs by
    /// size; an unmatched start leaks memory until the manager is deallocated.
    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize)

    /// Stops pre-caching thumbnails for the given identifiers.
    ///
    /// `targetSize` must exactly match the value passed to `startCachingThumbnails`.
    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize)

    /// Cancels all outstanding caching requests and releases associated memory.
    func stopCachingAllThumbnails()

    /// Returns an `AVPlayerItem` for the given video asset alongside a cancel
    /// handle for the underlying PhotoKit request.
    ///
    /// The handle stays valid until PhotoKit reports final delivery; calling
    /// `cancel()` after that is a no-op. Callers that no longer need the item
    /// (e.g. an LRU pool evicting a slot) should call `cancel()` to stop any
    /// in-flight iCloud download and release its bandwidth. Mocks may return
    /// a `nil` handle to indicate there is nothing to cancel.
    ///
    /// `progressHandler` receives values in [0.0, 1.0] on an arbitrary PhotoKit
    /// callback queue; pass `nil` when progress reporting is not needed.
    func avPlayerItem(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> (item: AVPlayerItem?, handle: VideoRequestHandle?)

    /// Returns a `PHLivePhoto` rendered at `targetSize` (pixels).
    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto?
}

/// Write operations that permanently or structurally modify the user's library.
///
/// Threading: `@MainActor`-isolated on concrete implementations.
@MainActor
protocol PhotoLibraryMutating: Sendable {
    /// Submits a batch of assets for permanent deletion.
    ///
    /// The real implementation presents the iOS system photo-deletion alert;
    /// all identifiers appear in a single prompt. Suspends until the user
    /// confirms or cancels.
    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult

    /// Creates a new user album with the given title.
    ///
    /// In dry-run mode returns a synthetic `UserAlbum` entry without issuing
    /// any PhotoKit `performChanges` call.
    func createUserAlbum(title: String) async -> UserAlbum?

    /// Moves assets between albums atomically.
    ///
    /// When `fromAlbumId` is `nil` (asset comes from All Photos) the
    /// operation is add-only. When `fromAlbumId` is set, both the
    /// remove-from-source and add-to-destination steps execute inside a
    /// single `performChanges` block.
    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult

    /// Removes assets from an album without deleting them from the library.
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult

    /// Sets or clears the Photos native favourite flag on a single asset.
    ///
    /// Returns `true` when the underlying `performChanges` call completes
    /// without error.
    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool

    /// Sets the Photos native favourite flag on a batch of assets in a single
    /// `performChanges` transaction. Returns `true` when the batch commits
    /// without error; a partial failure returns `false` and leaves no assets
    /// modified. Empty input returns `true`.
    func setFavorites(_ ids: [AssetIdentifier], isFavorite: Bool) async -> Bool
}

// MARK: - Composed protocol (backward-compatible typealias)

/// The full photo-library interface combining read, cache, and mutating surfaces.
///
/// `PhotoKitLibrary` and `MockPhotoLibrary` conform to this typealias.
/// All existing `let library: PhotoLibraryProviding` declarations remain valid —
/// the typealias is source-compatible with the former `protocol PhotoLibraryProviding`.
///
/// Threading: concrete implementations are `@MainActor`-isolated. All callers
/// must be `@MainActor`-isolated or cross the actor boundary with `await`.
typealias PhotoLibraryProviding = PhotoLibraryReadProviding & PhotoLibraryCacheProviding & PhotoLibraryMutating

// MARK: - Default implementations


extension PhotoLibraryReadProviding {
    func thumbnailStream(for identifier: AssetIdentifier, targetSize: CGSize) -> AsyncStream<AssetThumbnail> {
        AsyncStream { continuation in
            let task = Task {
                if let thumb = await thumbnail(for: identifier, targetSize: targetSize) {
                    continuation.yield(thumb)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    // Default implementation falls back to identifier-based lookup.
    // MockPhotoLibrary relies on this; PhotoKitLibrary overrides with O(1) access.
    func assetMetadata(at index: Int, expectedId: AssetIdentifier) async -> AssetMetadata? {
        let kind = await mediaKind(for: expectedId)
        let fav = await isFavorite(for: expectedId)
        return AssetMetadata(id: expectedId, mediaKind: kind, isFavorite: fav)
    }
}

extension PhotoLibraryMutating where Self: PhotoLibraryReadProviding {
    /// Photos.app "make consistent" toggle: if any asset in `ids` is not
    /// favourited, favourite them all; otherwise unfavourite them all. The
    /// scan short-circuits on the first non-favourite, then commits a single
    /// batch `setFavorites` transaction.
    func toggleFavoritesConsistently(_ ids: [AssetIdentifier]) async -> Bool {
        guard !ids.isEmpty else { return true }
        var anyNotFavorite = false
        for id in ids {
            if await !isFavorite(for: id) { anyNotFavorite = true; break }
        }
        return await setFavorites(ids, isFavorite: anyNotFavorite)
    }
}

