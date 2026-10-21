import Foundation
import Photos
import PhotosUI
import AVFoundation
import UIKit

/// Production `PhotoLibraryProviding` backed by PhotoKit.
///
/// The class owns a single `PHCachingImageManager` and a lazily-populated
/// `PHFetchResult<PHAsset>` cursor. The cursor is never materialised to an
/// array; callers read individual assets or contiguous index ranges through
/// `ensureFetchResult()`.
///
/// Threading: `@MainActor`-isolated (W1 fix). The three mutable stored
/// properties — `fetchResult`, `fetchedAuth`, and `activeFilter` — are
/// protected by actor isolation rather than a lock. All production callers
/// (`SwipeSessionModel`, `WindowedThumbnailCache`) are `@MainActor`-isolated,
/// so no `await` is needed at call sites for synchronous methods. A full
/// `actor` upgrade was considered but rejected: the synchronous protocol
/// requirements `startCachingThumbnails` / `stopCachingThumbnails` cannot
/// be made `async` without breaking `WindowedThumbnailCache`'s calling
/// convention and the `PhotoLibraryProviding` protocol surface.
///
/// PhotoKit invariant: every `requestImage` call uses pixel-scaled
/// `targetSize`, `.aspectFill` content mode, `.opportunistic` delivery
/// where appropriate, and `isNetworkAccessAllowed = false`. iCloud-only
/// assets are intentionally unsupported to enforce a local-only workflow.
// @MainActor-isolated. Conforms to PhotoLibraryProviding (= ReadProviding &
// CacheProviding & Mutating) as a composed typealias. All three sub-protocol
// requirements are implemented in the extension groups below.
@MainActor
final class PhotoKitLibrary: PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating {

    private let imageManager = PHCachingImageManager()
    private var fetchResult: PHFetchResult<PHAsset>?
    private var fetchedAuth: PhotoLibraryAuthorization = .notDetermined
    private var activeFilter: SwipeFilter = .unfiltered
    private let albumId: String?

    /// Set by `applyPhotoKitChange(_:)` when an incoming `PHChange` actually
    /// affected our fetch result. Consumed and cleared by `refreshFetchResult()`.
    private var pendingChange: Bool = false

    /// Creates a library instance optionally scoped to a single album.
    ///
    /// Observer registration: `PhotoLibraryChangePublisher.shared.register()` is
    /// intentionally NOT called here. The call site that confirms authorization
    /// (`SwipeSessionModel.start()`) is responsible for calling `register()` after
    /// `.authorized` or `.limited` is confirmed. This prevents the observer from
    /// firing before a valid fetch cursor exists (W6 fix).
    ///
    /// The instance also attaches itself to the shared publisher's weak-ref
    /// table so incoming `PHChange` events can update its fetch cursor in place.
    /// Attach is safe pre-authorization: with no cursor, `applyPhotoKitChange`
    /// is a no-op until the first `ensureFetchResult()` call.
    init(albumId: String? = nil) {
        self.albumId = albumId
        PhotoLibraryChangePublisher.shared.attach(self)
    }

    /// Returns a new `PhotoKitLibrary` whose fetch result is scoped to `albumId`.
    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding {
        PhotoKitLibrary(albumId: albumId)
    }

    func currentAuthorization() async -> PhotoLibraryAuthorization {
        map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: self.map(status))
            }
        }
    }

    func assetCount() async -> Int {
        await ensureFetchResult().count
    }

    func assetIdentifier(at index: Int) async -> AssetIdentifier? {
        let result = await ensureFetchResult()
        guard (0..<result.count).contains(index) else { return nil }
        return AssetIdentifier(result.object(at: index).localIdentifier)
    }

    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int? {
        let result = await ensureFetchResult()
        let matched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = matched.firstObject else { return nil }
        let index = result.index(of: asset)
        return index != NSNotFound ? index : nil
    }

    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? {
        var finalThumb: AssetThumbnail?
        for await thumb in thumbnailStream(for: identifier, targetSize: targetSize) {
            finalThumb = thumb
            if !thumb.isDegraded {
                break
            }
        }
        return finalThumb
    }

    private final class ImageStreamRequestHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID = PHInvalidImageRequestID

        func store(_ id: PHImageRequestID) {
            lock.lock()
            defer { lock.unlock() }
            requestID = id
        }

        func cancel(using manager: PHCachingImageManager) {
            lock.lock()
            let id = requestID
            lock.unlock()
            if id != PHInvalidImageRequestID {
                manager.cancelImageRequest(id)
            }
        }
    }

    func thumbnailStream(for identifier: AssetIdentifier, targetSize: CGSize) -> AsyncStream<AssetThumbnail> {
        // Fetch by localIdentifier rather than enumerating the full PHFetchResult;
        // Photos DB lookup is O(1) regardless of library size.
        let matched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier.rawValue], options: nil)
        guard let asset = matched.firstObject else {
            return AsyncStream { $0.finish() }
        }

        let options = cachingRequestOptions()
        options.isSynchronous = false

        let imageManager = self.imageManager
        return AsyncStream { continuation in
            let holder = ImageStreamRequestHolder()
            let requestID = imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false

                if let image {
                    continuation.yield(AssetThumbnail(
                        identifier: identifier,
                        image: image,
                        isDegraded: isDegraded
                    ))
                    if !isDegraded {
                        continuation.finish()
                    }
                } else if hasError || cancelled || !isDegraded {
                    continuation.finish()
                }
            }
            holder.store(requestID)

            continuation.onTermination = { @Sendable _ in
                holder.cancel(using: imageManager)
            }
        }
    }

    func assetMetadata(at index: Int, expectedId: AssetIdentifier) async -> AssetMetadata? {
        let result = await ensureFetchResult()
        let asset: PHAsset
        
        // Fast path: O(1) array access.
        if index >= 0 && index < result.count, result.object(at: index).localIdentifier == expectedId.rawValue {
            asset = result.object(at: index)
        } else {
            // Fallback: The index shifted due to a background mutation before UI refreshed.
            let matched = PHAsset.fetchAssets(withLocalIdentifiers: [expectedId.rawValue], options: nil)
            guard let matchedAsset = matched.firstObject else { return nil }
            asset = matchedAsset
        }
        
        let kind: MediaKind
        if asset.mediaType == .video {
            kind = .video(durationSeconds: asset.duration)
        } else if asset.mediaSubtypes.contains(.photoLive) {
            kind = .livePhoto
        } else {
            kind = .photo
        }
        
        return AssetMetadata(id: expectedId, mediaKind: kind, isFavorite: asset.isFavorite)
    }

    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult {
        guard !identifiers.isEmpty else { return .success(affectedCount: 0) }

        if DryRunMode.isEnabled {
            DryRunMode.log("Would delete \(identifiers.count) asset(s): \(identifiers.map(\.rawValue))")
            return .success(affectedCount: identifiers.count)
        }

        let rawIds = identifiers.map(\.rawValue)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: rawIds, options: nil)

        var deletable: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            if asset.canPerform(.delete) {
                deletable.append(asset)
            }
        }

        guard !deletable.isEmpty else {
            return .failed(reason: "No deletable assets in batch (permissions or read-only).")
        }

        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.deleteAssets(deletable as NSArray)
                }, completionHandler: { success, error in
                    if success {
                        cont.resume(returning: .success(affectedCount: deletable.count))
                        return
                    }
                    if let ns = error as NSError?, ns.domain == PHPhotosErrorDomain,
                       ns.code == PHPhotosError.userCancelled.rawValue {
                        cont.resume(returning: .cancelledByUser)
                        return
                    }
                    cont.resume(returning: .failed(reason: error?.localizedDescription ?? "unknown"))
                })
            }
        }
    }

    // MARK: - Albums

    func userAlbums() async -> [UserAlbum] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        let fetched = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: opts
        )
        // Hand the fetch to the publisher so subsequent PHChanges can be diffed
        // against it — `.albumsDidChangeNotification` fires only when this
        // specific fetch is affected, sparing AlbumsView from asset-only edits.
        PhotoLibraryChangePublisher.shared.attachAlbumsFetch(fetched)
        var out: [UserAlbum] = []
        fetched.enumerateObjects { col, _, _ in
            let title = col.localizedTitle ?? "Untitled"
            let canAdd = col.canPerform(.addContent)
            let count: Int
            if col.estimatedAssetCount != NSNotFound {
                count = col.estimatedAssetCount
            } else {
                let countFetch = PHAsset.fetchAssets(in: col, options: nil)
                count = countFetch.count
            }
            
            out.append(UserAlbum(
                id: col.localIdentifier,
                title: title,
                assetCount: count,
                canAdd: canAdd
            ))
        }
        return out
    }

    func createUserAlbum(title: String) async -> UserAlbum? {
        if DryRunMode.isEnabled {
            DryRunMode.log("Would create album titled \(title)")
            return UserAlbum(
                id: "dryrun-\(UUID().uuidString)",
                title: title,
                assetCount: 0,
                canAdd: true
            )
        }
        var placeholderId: String?
        let ok: Bool = await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                placeholderId = req.placeholderForCreatedAssetCollection.localIdentifier
            }, completionHandler: { success, _ in
                cont.resume(returning: success)
            })
        }
        guard ok, let id = placeholderId else { return nil }
        return UserAlbum(id: id, title: title, assetCount: 0, canAdd: true)
    }

    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult {
        guard !ids.isEmpty else { return .success(affectedCount: 0) }

        if DryRunMode.isEnabled {
            let src = fromAlbumId ?? "AllPhotos"
            DryRunMode.log("Would move \(ids.count) asset(s) from \(src) to \(toAlbumId)")
            return .success(affectedCount: ids.count)
        }

        let destFetch = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [toAlbumId], options: nil
        )
        guard let dest = destFetch.firstObject, dest.canPerform(.addContent) else {
            return .failed(reason: "Destination album not writable.")
        }

        var source: PHAssetCollection?
        if let fromId = fromAlbumId {
            let srcFetch = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [fromId], options: nil
            )
            guard let s = srcFetch.firstObject, s.canPerform(.removeContent) else {
                return .failed(reason: "Source album does not permit removals (likely a smart album).")
            }
            source = s
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                // Both remove-from-source and add-to-destination execute in a
                // single performChanges block so a partial failure never leaves
                // an asset in both albums or in neither (iCloud-visible atomicity).
                if let src = source, let removeReq = PHAssetCollectionChangeRequest(for: src) {
                    removeReq.removeAssets(assets as NSFastEnumeration)
                }
                if let addReq = PHAssetCollectionChangeRequest(for: dest) {
                    addReq.addAssets(assets as NSFastEnumeration)
                }
            }, completionHandler: { success, error in
                if success {
                    cont.resume(returning: .success(affectedCount: ids.count))
                    return
                }
                if let ns = error as NSError?,
                   ns.domain == PHPhotosErrorDomain,
                   ns.code == PHPhotosError.userCancelled.rawValue {
                    cont.resume(returning: .cancelledByUser)
                    return
                }
                cont.resume(returning: .failed(reason: error?.localizedDescription ?? "unknown"))
            })
        }
    }

    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        guard !ids.isEmpty else { return .success(affectedCount: 0) }

        if DryRunMode.isEnabled {
            DryRunMode.log("Would remove \(ids.count) asset(s) from \(albumId)")
            return .success(affectedCount: ids.count)
        }

        let fetch = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil
        )
        guard let album = fetch.firstObject, album.canPerform(.removeContent) else {
            return .failed(reason: "Album does not permit removals.")
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                if let req = PHAssetCollectionChangeRequest(for: album) {
                    req.removeAssets(assets as NSFastEnumeration)
                }
            }, completionHandler: { success, error in
                if success {
                    cont.resume(returning: .success(affectedCount: ids.count))
                    return
                }
                if let ns = error as NSError?,
                   ns.domain == PHPhotosErrorDomain,
                   ns.code == PHPhotosError.userCancelled.rawValue {
                    cont.resume(returning: .cancelledByUser)
                    return
                }
                cont.resume(returning: .failed(reason: error?.localizedDescription ?? "unknown"))
            })
        }
    }

    func isFavorite(for id: AssetIdentifier) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        return assets.firstObject?.isFavorite ?? false
    }

    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool {
        if DryRunMode.isEnabled {
            DryRunMode.log("Would set favorite=\(isFavorite) on \(id.rawValue)")
            return true
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = assets.firstObject else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest(for: asset)
                req.isFavorite = isFavorite
            }, completionHandler: { ok, _ in
                cont.resume(returning: ok)
            })
        }
    }

    func setFavorites(_ ids: [AssetIdentifier], isFavorite: Bool) async -> Bool {
        guard !ids.isEmpty else { return true }
        if DryRunMode.isEnabled {
            DryRunMode.log("Would set favorite=\(isFavorite) on \(ids.count) assets")
            return true
        }
        let raw = ids.map(\.rawValue)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: raw, options: nil)
        guard fetched.count > 0 else { return false }
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                for asset in assets {
                    let req = PHAssetChangeRequest(for: asset)
                    req.isFavorite = isFavorite
                }
            }, completionHandler: { ok, _ in
                cont.resume(returning: ok)
            })
        }
    }

    // MARK: - Media

    func mediaKind(for id: AssetIdentifier) async -> MediaKind {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = fetched.firstObject else { return .photo }
        if asset.mediaType == .video {
            return .video(durationSeconds: asset.duration)
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            return .livePhoto
        }
        return .photo
    }

    func identifiers(in range: Range<Int>) async -> [AssetIdentifier] {
        let result = await ensureFetchResult()
        let clamped = range.clamped(to: 0..<result.count)
        guard !clamped.isEmpty else { return [] }
        let indexSet = IndexSet(integersIn: clamped)
        return result.objects(at: indexSet).map { AssetIdentifier($0.localIdentifier) }
    }

    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {
        let assets = resolveAssets(ids)
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: cachingRequestOptions()
        )
    }

    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {
        let assets = resolveAssets(ids)
        guard !assets.isEmpty else { return }
        // The (targetSize, contentMode, options) triple must be byte-identical
        // to the matching startCachingImages call; PHCachingImageManager uses it
        // as a reference-count key and silently leaks memory when they differ.
        // Both paths use cachingRequestOptions() to ensure consistency.
        imageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: cachingRequestOptions()
        )
    }

    func stopCachingAllThumbnails() {
        imageManager.stopCachingImagesForAllAssets()
    }

    func avPlayerItem(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> (item: AVPlayerItem?, handle: VideoRequestHandle?) {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = fetched.firstObject, asset.mediaType == .video else { return (nil, nil) }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .automatic
        let handleBox = PhotoKitVideoRequestHandle(imageManager: imageManager)
        let item: AVPlayerItem? = await withCheckedContinuation { cont in
            let lock = NSLock()
            var resumed = false
            let requestID = imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: item)
            }
            handleBox.setRequestID(requestID)
        }
        return (item, handleBox)
    }

    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = fetched.firstObject else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { cont in
            // NSLock prevents double-resume for the same reason as thumbnail(for:).
            // Additional hazard: on a slow iCloud connection PhotoKit may deliver
            // live==nil, isDegraded==true (download in progress) as a first callback
            // and then never call back again if the connection drops. The continuation
            // would hang until the session is torn down. A production fix would add
            // a withTaskCancellationHandler and a timeout path.
            let lock = NSLock()
            var resumed = false
            imageManager.requestLivePhoto(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { live, info in
                let isDegraded = (info?[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                let hasError = info?[PHLivePhotoInfoErrorKey] != nil
                let cancelled = (info?[PHLivePhotoInfoCancelledKey] as? Bool) ?? false
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                if live != nil {
                    resumed = true
                    cont.resume(returning: live)
                    return
                }
                if hasError || cancelled || !isDegraded {
                    resumed = true
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Returns the `PHImageRequestOptions` instance shared by all caching calls.
    ///
    /// Centralising option construction ensures `startCachingThumbnails` and
    /// `stopCachingThumbnails` always pass byte-identical parameters to
    /// `PHCachingImageManager`, satisfying its reference-count invariant.
    private func cachingRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return options
    }

    private func resolveAssets(_ ids: [AssetIdentifier]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        var out: [PHAsset] = []
        out.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// Returns the cached `PHFetchResult`, rebuilding it if the authorization
    /// state changed or the cursor was invalidated by `refreshFetchResult()`.
    ///
    /// Why: pre-authorization fetches return an empty result; caching that
    /// empty result would leave `assetCount` at 0 even after the user grants
    /// access. The `fetchedAuth` guard ensures the cached cursor is only reused
    /// once a usable authorization state is confirmed.
    private func ensureFetchResult() async -> PHFetchResult<PHAsset> {
        // Reuse the cached fetch only if it was built after authorization was granted.
        let currentAuth = map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        let authIsUsable = currentAuth == .authorized || currentAuth == .limited
        if let existing = fetchResult, fetchedAuth == currentAuth, authIsUsable {
            return existing
        }
        let options = PHFetchOptions()
        options.sortDescriptors = activeFilter.nsSortDescriptors()
        if let predicate = activeFilter.nsPredicate() {
            options.predicate = predicate
        }
        let result: PHFetchResult<PHAsset>
        if let albumId,
           let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        fetchResult = result
        fetchedAuth = currentAuth
        return result
    }

    /// Applies a `PHChange` from `PhotoLibraryChangePublisher` to this library's
    /// fetch result. Called on the main actor before `.didChangeNotification`
    /// is posted.
    ///
    /// Behavior:
    /// - No cursor yet → nothing to diff against. Skip.
    /// - `changeDetails(for:)` returns `nil` → this change did not touch our
    ///   fetch result. Skip; downstream observers can no-op.
    /// - Otherwise → update the cursor in place via `fetchResultAfterChanges`
    ///   and flag `pendingChange` so the next `refreshFetchResult()` reports
    ///   a real change.
    func applyPhotoKitChange(_ change: PHChange) {
        guard let current = fetchResult,
              let details = change.changeDetails(for: current) else { return }
        fetchResult = details.fetchResultAfterChanges
        pendingChange = true
    }

    func refreshFetchResult() async -> Bool {
        // Cold path: no cursor yet. `ensureFetchResult()` will build one on the
        // next access; callers must treat downstream state as new.
        if fetchResult == nil {
            return true
        }
        // Warm path: only report a change when `applyPhotoKitChange` marked one.
        // A stray notification for content outside our fetch result no longer
        // forces a generation bump.
        if pendingChange {
            pendingChange = false
            return true
        }
        return false
    }

    func applyFilter(_ filter: SwipeFilter) async {
        // Invalidate the cursor only when the filter actually changed. The
        // "library changed underneath us" case now flows through
        // `applyPhotoKitChange`, so callers no longer need `applyFilter` as a
        // catch-all refresh trigger.
        let filterChanged = filter != activeFilter
        guard filterChanged else { return }
        activeFilter = filter
        fetchResult = nil
        pendingChange = false
        imageManager.stopCachingImagesForAllAssets()
    }

    nonisolated private func map(_ status: PHAuthorizationStatus) -> PhotoLibraryAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:   return .restricted
        case .denied:       return .denied
        case .authorized:   return .authorized
        case .limited:      return .limited
        @unknown default:   return .denied
        }
    }
}

/// Cancel handle for a `PHCachingImageManager.requestPlayerItem` request.
///
/// The request ID is captured just after `requestPlayerItem` returns, so the
/// handle is stored in the pool *before* PhotoKit's completion fires. If the
/// pool evicts the slot before the download completes, `cancel()` releases
/// the iCloud bandwidth reserved for the request.
///
/// Threading: `PHCachingImageManager.cancelImageRequest(_:)` is safe to call
/// from any thread. The `NSLock` guards against a race where the completion
/// callback and an eviction try to mutate `state` concurrently — including
/// the case where `cancel()` arrives before `setRequestID` has run.
final class PhotoKitVideoRequestHandle: VideoRequestHandle, @unchecked Sendable {
    private enum State {
        case pending
        case assigned(PHImageRequestID)
        case cancelled
    }

    private let imageManager: PHCachingImageManager
    private let lock = NSLock()
    private var state: State = .pending

    init(imageManager: PHCachingImageManager) {
        self.imageManager = imageManager
    }

    fileprivate func setRequestID(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .pending:   state = .assigned(id)
        case .cancelled: imageManager.cancelImageRequest(id)
        case .assigned:  break
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .assigned(let id): imageManager.cancelImageRequest(id)
        case .pending:          break
        case .cancelled:        return
        }
        state = .cancelled
    }
}
