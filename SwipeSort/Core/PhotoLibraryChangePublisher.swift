import Foundation
import Photos

/// Singleton bridge between `PHPhotoLibraryChangeObserver` and `NotificationCenter`.
///
/// Translates `PHPhotoLibraryChangeObserver` callbacks into two things, in
/// order, on the main actor:
///   1. Each attached `PhotoKitLibrary` gets `applyPhotoKitChange(_:)` so it
///      can update its fetch cursor in place via `fetchResultAfterChanges`.
///   2. A single `.didChangeNotification` post lets SwiftUI views subscribe
///      with `.onReceive` and call `library.refreshFetchResult()` — which is
///      now a no-op unless the change actually touched that library's fetch.
///
/// `RecentsView` and `AlbumsView` subscribe to `didChangeNotification` to
/// refresh their grids automatically after a deletion or album move commits.
///
/// Registration ordering invariant: `register()` must be called only after
/// the user has granted photo-library access (`.authorized` or `.limited`).
/// Why: registering before authorization is granted causes PhotoKit to invoke
/// `photoLibraryDidChange` on every library change even when the app has no
/// valid fetch cursor, triggering unnecessary reload work.
// @unchecked Sendable is justified: the only mutable stored properties
// (`isRegistered`, `libraries`) are written exclusively from
// `@MainActor`-isolated callers. `photoLibraryDidChange(_:)` is invoked by
// PhotoKit on a background thread but immediately hops to the main queue
// before reading either property.
final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    /// The shared instance. The observer is registered lazily via `register()`.
    static let shared = PhotoLibraryChangePublisher()

    /// Posted on the main queue after any photo-library change.
    ///
    /// By the time observers receive this, every attached `PhotoKitLibrary` has
    /// already had its fetch cursor updated in place. Observers should call
    /// `library.refreshFetchResult()` to learn whether *their* library changed;
    /// unrelated notifications now return `false` and cost nothing downstream.
    static let didChangeNotification = Notification.Name("PhotoLibraryDidChange")

    /// Posted on the main queue only when a `PHChange` actually affected the
    /// user's album list (adds, removes, renames, order changes).
    ///
    /// `AlbumsView` and `AlbumPickerSheet` subscribe to this so their
    /// `userAlbums()` refetch fires only when the album list truly changed —
    /// not on every asset edit inside an album.
    static let albumsDidChangeNotification = Notification.Name("PhotoLibraryAlbumsDidChange")

    /// Idempotency guard. Accessed only from `@MainActor`-isolated callers
    /// (SwipeSessionModel.start()), so no additional locking is required.
    private var isRegistered = false

    /// Weak references to every live `PhotoKitLibrary` instance. Populated by
    /// `attach(_:)` at library init; entries auto-clear when the underlying
    /// library is deallocated (`NSHashTable.weakObjects()`).
    private let libraries = NSHashTable<PhotoKitLibrary>.weakObjects()

    /// Latest `PHFetchResult` of user albums, kept so incoming `PHChange`s can
    /// be diffed against it via `changeDetails(for:)`. Refreshed every time
    /// `PhotoKitLibrary.userAlbums()` runs. `nil` until the first fetch.
    private var albumsFetch: PHFetchResult<PHAssetCollection>?

    private override init() {}

    /// Registers this observer with `PHPhotoLibrary`.
    ///
    /// Safe to call more than once — subsequent calls are no-ops. Must be called
    /// only after photo-library access is granted (`.authorized` or `.limited`).
    /// Calling before authorization is confirmed may trigger spurious
    /// `photoLibraryDidChange` callbacks against an invalid fetch cursor (W6 fix).
    ///
    /// `@MainActor` ensures `isRegistered` is only written on the main actor,
    /// making the `@unchecked Sendable` opt-out on the class sound (N1 fix).
    @MainActor
    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        PHPhotoLibrary.shared().register(self)
    }

    /// Registers only if the current authorization status is `.authorized` or
    /// `.limited`. Called from every grid-loading path so a user who only
    /// browses Recents or Albums (never opens a swipe session) still gets
    /// live-update notifications for external library edits.
    @MainActor
    func registerIfAuthorized() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        register()
    }

    /// Adds `library` to the set of instances that receive `applyPhotoKitChange(_:)`
    /// dispatches. Called from `PhotoKitLibrary.init`; weak storage means no
    /// matching `detach` is required.
    @MainActor
    func attach(_ library: PhotoKitLibrary) {
        libraries.add(library)
    }

    /// Registers the latest album fetch so incoming `PHChange`s can be diffed
    /// against it. Called from `PhotoKitLibrary.userAlbums()` each time the
    /// album list is refetched. Overwriting is intentional — the most recent
    /// fetch is always the correct baseline for future diffs.
    @MainActor
    func attachAlbumsFetch(_ fetch: PHFetchResult<PHAssetCollection>) {
        albumsFetch = fetch
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // NSHashTable.allObjects snapshots live entries; iterating the
            // snapshot is safe even if a library is deallocated mid-loop.
            for library in self.libraries.allObjects {
                MainActor.assumeIsolated {
                    library.applyPhotoKitChange(changeInstance)
                }
            }

            // Diff the album fetch. Non-nil means the album list itself moved
            // (add / delete / rename / reorder). Update the baseline in place
            // and emit the precise notification; skip otherwise so asset-only
            // edits don't wake AlbumsView.
            var albumsChanged = false
            if let fetch = self.albumsFetch,
               let details = changeInstance.changeDetails(for: fetch) {
                self.albumsFetch = details.fetchResultAfterChanges
                albumsChanged = true
            }

            NotificationCenter.default.post(
                name: PhotoLibraryChangePublisher.didChangeNotification,
                object: nil
            )
            if albumsChanged {
                NotificationCenter.default.post(
                    name: PhotoLibraryChangePublisher.albumsDidChangeNotification,
                    object: nil
                )
            }
        }
    }
}
