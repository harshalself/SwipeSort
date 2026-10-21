#if DEBUG
import Foundation
import UIKit
import AVFoundation
import PhotosUI

/// Deterministic in-memory `PhotoLibraryProviding` for tests and UI previews.
///
/// Generates solid-colour placeholder thumbnails derived from the asset
/// identifier's hash so view-model and UI tests can assert on image presence
/// without a real photo library.
///
/// Threading: `@MainActor`-isolated (W2 fix), mirroring `PhotoKitLibrary`.
/// Swift Testing runs `async` test functions on the main actor by default,
/// so `@MainActor` on `MockPhotoLibrary` adds zero runtime cost in tests while
/// making the conformance sound — all mutable stored properties are protected
/// by actor isolation rather than the previous documentation-only convention.
// @MainActor-isolated. Conforms to PhotoLibraryProviding (= ReadProviding &
// CacheProviding & Mutating) as a composed typealias. All three sub-protocol
// requirements are implemented inline.
@MainActor
final class MockPhotoLibrary: PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating {

    private var currentAuth: PhotoLibraryAuthorization
    private let count: Int
    var nextAuthorizationDecision: PhotoLibraryAuthorization?

    private(set) var lastCommittedDeletions: [AssetIdentifier] = []
    var nextCommitResult: CommitResult?

    // Album state
    private var albums: [UserAlbum] = []
    /// All move operations recorded by `moveAssets(_:fromAlbumId:toAlbumId:)`.
    private(set) var lastMoves: [(from: String?, to: String, ids: [AssetIdentifier])] = []
    /// All `removeAssetsFromAlbum` calls, in order — tracked for test assertions.
    private(set) var lastRemoves: [(albumId: String, ids: [AssetIdentifier])] = []
    /// The favourite flag set on each asset by `setFavorite(_:isFavorite:)`.
    private(set) var favoriteState: [AssetIdentifier: Bool] = [:]
    /// When set, `moveAssets` returns this result instead of the default `.success`.
    var nextMoveResult: CommitResult?
    /// When set, `removeAssetsFromAlbum` returns this result instead of the default
    /// `.success`. Consumed once — reset to `nil` after each call so a scripted
    /// failure cannot leak into subsequent tests through a shared mock.
    var nextRemoveResult: CommitResult?
    /// When set, `createUserAlbum` returns this album instead of synthesising one.
    var nextCreatedAlbum: UserAlbum?

    // Media kind state
    /// Maps `AssetIdentifier.rawValue` to a scripted `MediaKind`. Unregistered
    /// identifiers default to `.photo`.
    var scriptedMediaKinds: [String: MediaKind] = [:]
    var scriptedThumbnails: [String: AssetThumbnail?] = [:]
    /// When set, the next call to `thumbnail(for:targetSize:)` returns this value
    /// instead of the default placeholder. Double-optional:
    ///   - `nil` outer: default behavior (synthesise a placeholder — existing tests).
    ///   - `.some(nil)`: return `nil` (F9 nil-thumbnail regression scenario).
    ///   - `.some(.some(x))`: return `x` (F9 degraded-thumbnail scenario).
    /// Consumed once — reset to `nil` after the call so subsequent thumbnail fetches
    /// use the default path.
    var nextThumbnailResult: AssetThumbnail??
    /// All `startCachingThumbnails` calls, in order.
    var startCachingCalls: [([AssetIdentifier], CGSize)] = []
    /// All `stopCachingThumbnails` calls, in order.
    var stopCachingCalls: [([AssetIdentifier], CGSize)] = []
    private(set) var stopAllCallCount = 0

    // Filter state
    private(set) var appliedFilter: SwipeFilter = .unfiltered
    /// When set, overrides `count` as the effective asset count for the current filter.
    var scriptedFilteredCount: Int?

    /// Value returned by the next call to `refreshFetchResult()`. Reset to `true`
    /// after each call so tests must opt in to the "unchanged" case each time.
    var nextRefreshReturnsChanged: Bool = true

    /// The album ID this instance was scoped to via `scoped(toAlbumId:)`, if any.
    var scopedAlbumId: String?

    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding {
        let copy = MockPhotoLibrary(authorization: currentAuth, assetCount: min(count, 5))
        copy.scopedAlbumId = albumId
        copy.albums = albums
        return copy
    }

    init(authorization: PhotoLibraryAuthorization, assetCount: Int) {
        self.currentAuth = authorization
        self.count = assetCount
    }

    func currentAuthorization() async -> PhotoLibraryAuthorization {
        currentAuth
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        if let decision = nextAuthorizationDecision {
            currentAuth = decision
        }
        return currentAuth
    }

    /// Overwrites the authorization state read by `currentAuthorization()`.
    ///
    /// Test-only hook for mid-session auth revocation scenarios. Distinct from
    /// `nextAuthorizationDecision`, which is only consumed by `requestAuthorization()`.
    func setCurrentAuthorization(_ auth: PhotoLibraryAuthorization) {
        currentAuth = auth
    }

    /// Effective count after the current filter. Tests that don't care about
    /// filtering leave `scriptedFilteredCount` nil and get the raw `count`.
    private var effectiveCount: Int { scriptedFilteredCount ?? count }

    func assetCount() async -> Int { effectiveCount }

    func assetIdentifier(at index: Int) async -> AssetIdentifier? {
        guard (0..<effectiveCount).contains(index) else { return nil }
        return AssetIdentifier("mock-asset-\(index)")
    }

    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int? {
        for i in 0..<effectiveCount {
            if await assetIdentifier(at: i) == id {
                return i
            }
        }
        return nil
    }

    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? {
        if let entry = scriptedThumbnails.index(forKey: identifier.rawValue) {
            return scriptedThumbnails.values[entry]
        }
        if let scripted = nextThumbnailResult {
            nextThumbnailResult = nil
            return scripted
        }
        let hash = abs(identifier.rawValue.hashValue) % 360
        let color = UIColor(hue: CGFloat(hash) / 360.0, saturation: 0.6, brightness: 0.9, alpha: 1.0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return AssetThumbnail(identifier: identifier, image: image, isDegraded: false)
    }

    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult {
        lastCommittedDeletions = identifiers
        if let scripted = nextCommitResult { return scripted }
        return .success(affectedCount: identifiers.count)
    }

    // MARK: - Albums

    /// Pre-populates the album list returned by `userAlbums()`.
    func seedAlbums(_ list: [UserAlbum]) { albums = list }

    func userAlbums() async -> [UserAlbum] { albums }

    func createUserAlbum(title: String) async -> UserAlbum? {
        if let scripted = nextCreatedAlbum {
            albums.append(scripted)
            return scripted
        }
        let new = UserAlbum(
            id: "alb-\(albums.count)-\(title)",
            title: title,
            assetCount: 0,
            canAdd: true
        )
        albums.append(new)
        return new
    }

    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult {
        lastMoves.append((fromAlbumId, toAlbumId, ids))
        if let from = fromAlbumId, let idx = albums.firstIndex(where: { $0.id == from }) {
            albums[idx].assetCount = max(0, albums[idx].assetCount - ids.count)
        }
        if let idx = albums.firstIndex(where: { $0.id == toAlbumId }) {
            albums[idx].assetCount += ids.count
        }
        if let scripted = nextMoveResult { return scripted }
        return .success(affectedCount: ids.count)
    }

    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        lastRemoves.append((albumId: albumId, ids: ids))
        if let idx = albums.firstIndex(where: { $0.id == albumId }) {
            albums[idx].assetCount = max(0, albums[idx].assetCount - ids.count)
        }
        if let scripted = nextRemoveResult {
            nextRemoveResult = nil
            return scripted
        }
        return .success(affectedCount: ids.count)
    }

    func isFavorite(for id: AssetIdentifier) async -> Bool {
        favoriteState[id] ?? false
    }

    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool {
        favoriteState[id] = isFavorite
        return true
    }

    func setFavorites(_ ids: [AssetIdentifier], isFavorite: Bool) async -> Bool {
        for id in ids { favoriteState[id] = isFavorite }
        return true
    }

    // MARK: - Media

    func mediaKind(for id: AssetIdentifier) async -> MediaKind {
        scriptedMediaKinds[id.rawValue] ?? .photo
    }

    /// Records every `identifiers(in:)` call range so tests can assert on
    /// batching behavior (e.g. dense vs sparse fetch splits).
    /// Records the range passed to each `identifiers(in:)` call — read/write from
    /// tests so they can reset between assertion phases.
    var identifiersCallRanges: [Range<Int>] = []

    func identifiers(in range: Range<Int>) async -> [AssetIdentifier] {
        identifiersCallRanges.append(range)
        let clamped = range.clamped(to: 0..<effectiveCount)
        return clamped.map { AssetIdentifier("mock-asset-\($0)") }
    }

    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {
        startCachingCalls.append((ids, targetSize))
    }

    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {
        stopCachingCalls.append((ids, targetSize))
    }

    func stopCachingAllThumbnails() {
        stopAllCallCount += 1
    }

    func avPlayerItem(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> (item: AVPlayerItem?, handle: VideoRequestHandle?) {
        (nil, nil)
    }

    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto? { nil }

    // MARK: - Filters

    func applyFilter(_ filter: SwipeFilter) async {
        appliedFilter = filter
    }

    func refreshFetchResult() async -> Bool {
        defer { nextRefreshReturnsChanged = true }
        return nextRefreshReturnsChanged
    }
}

/// Test-inspectable `VideoRequestHandle`. `cancel()` flips `isCancelled` so
/// tests can assert that an LRU eviction cancelled the underlying request.
final class MockVideoRequestHandle: VideoRequestHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}
#endif
