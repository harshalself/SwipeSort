# SwipeSort — Research Findings

Deep research conducted 2026-07-06 across four axes: competitor landscape, PhotoKit constraints, feature gaps, performance gotchas. This document is the single source of truth for design decisions; every plan should cite it rather than re-research.

**Scope reminder:** SwipeSort is personal-use, no App Store deployment, no pricing. Sections tagged `[deploy-only]` are captured for completeness but not acted on.

---

## 1. Competitor Landscape `[deploy-only]`

| App                | Model                                    | Gestures                                | Standout                              | Top 1★ complaints                                                                                          |
|--------------------|------------------------------------------|-----------------------------------------|---------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Slidebox**       | Free + IAP ($19.99/yr, $29.99 one-time)  | Swipe UP = trash; tap album to sort     | Duplicate compare, Live Photo support | Progress resets on update; mass-delete tedious; no auto-detection; photo backup service sunsetting Feb 2026 |
| **Swipewipe**      | Free + ads, $29.99/yr                    | Left = delete, right = keep; month-by-month | "On This Day" streaks, memory map | Fake trial → instant charge; cancellation friction; escalating month cooldowns; delete not obvious        |
| **Gemini Photos**  | Discontinued → **CleanMy®Phone** $36.99/yr | Swipe + bulk mode                    | AI dupe/blur detection                | Paywall behind "free" listing; endless scan loops on large libraries; laggy multi-select                  |
| **Clever Cleaner** | **Truly free, no ads, no IAP**           | Left/right swipe added June 2025        | AI dupes, Live Photo compression      | Very little negative surface — the reputational threat                                                     |

Sources: [Slidebox](https://apps.apple.com/us/app/slidebox-photo-cleaner-app/id984305203), [Swipewipe](https://apps.apple.com/us/app/swipewipe-photo-cleaner/id1583884012), [CleanMy Phone](https://apps.apple.com/us/app/cleanmy-phone-cleanup-storage/id1277110040), [Clever Cleaner](https://apps.apple.com/us/app/clever-cleaner-ai-cleanup-app/id1666645584), [Apple discussion on Swipewipe charge](https://discussions.apple.com/thread/255636611).

---

## 2. PhotoKit / iOS Technical Constraints

### 2.1 Moving assets between user albums

Albums hold **references** to `PHAsset`s — the asset itself lives in the library and is never duplicated. Inside a single `PHPhotoLibrary.shared().performChanges` block, create two `PHAssetCollectionChangeRequest(for:)` requests — one for the source calling `removeAssets(_:)`, one for the destination calling `addAssets(_:)`. Both commit atomically.

Gate every mutation with `PHAssetCollection.canPerform(.removeContent)` / `.addContent`. **Smart albums** (Favorites, Recently Added, Screenshots, Selfies, Videos, Bursts, Panoramas, Recently Deleted) return `false` for these — you cannot mutate their membership. Toggle Favorites via `PHAssetChangeRequest.isFavorite` on the asset instead.

Docs: [PHAssetCollectionChangeRequest](https://developer.apple.com/documentation/photokit/phassetcollectionchangerequest).

### 2.2 Deletion flow

`PHAssetChangeRequest.deleteAssets(_ assets: NSFastEnumeration)` **always** shows a system confirmation alert. There is no API to suppress it. **Batch every pending deletion into one call** to get one prompt. Deleted assets go to **Recently Deleted** (recoverable ~30 days). On cancel, the completion handler returns `success = false` with `NSError` in `PHPhotosErrorDomain` — check for `PHPhotosError.userCancelled`. Gate first with `asset.canPerform(.delete)`.

Docs: [PHAssetChangeRequest](https://developer.apple.com/documentation/photokit/phassetchangerequest).

### 2.3 iCloud Photos (non-local assets)

- `PHImageRequestOptions.isNetworkAccessAllowed` defaults to **`false`** — if the full asset is only in iCloud you get `nil` (or a degraded thumbnail) plus `info[PHImageResultIsInCloudKey] = true`. Set it to `true` to download.
- `version`: `.current` (edited) / `.original` (source, e.g. real RAW) / `.unadjusted`.
- `deliveryMode`: `.opportunistic` (multi-callback; async only) / `.highQualityFormat` / `.fastFormat`.
- `contentMode`: `.aspectFit` / `.aspectFill` with a real `targetSize` (avoid `PHImageManagerMaximumSize`).
- `progressHandler` fires on a background queue during iCloud fetch with a `stop` pointer for cancellation.
- **No cellular flag exists** on `PHImageRequestOptions` — the system honors Settings → Photos → Cellular Data.
- For originals/videos, use `PHAssetResourceManager` with `PHAssetResourceRequestOptions.isNetworkAccessAllowed`.

Docs: [PHImageRequestOptions](https://developer.apple.com/documentation/photokit/phimagerequestoptions).

### 2.4 Composite media

- **Live Photos** (`PHAssetMediaSubtype.photoLive`): one `PHAsset` with `PHAssetResourceType.photo` + `.pairedVideo` — delete/move is atomic (both go together).
- **RAW+JPEG / ProRAW**: one `PHAsset` with `.photo` + `.alternatePhoto` resources; deletion removes both. Pick RAW with `version = .original`.
- **HEIC**: transparent — request through normal image APIs.
- **Bursts**: each frame is a **separate** `PHAsset` sharing `burstIdentifier`. Only one has `representsBurst == true`. Default fetches hide non-representatives — set `PHFetchOptions.includeAllBurstAssets = true` and predicate on `burstIdentifier` to delete the whole burst. Deletion does **not** cascade.

### 2.5 System / smart albums

Read-only for membership. Cannot add/remove/rearrange in Screenshots, Selfies, Videos, Bursts, Panoramas, or Recently Deleted. Recently Deleted is entirely opaque to third-party apps. You **can** create/delete your own user albums via `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)` and `deleteAssetCollections(_:)`.

### 2.6 Limited access (`PHAuthorizationStatus.limited`)

Fetches return only the user-picked subset — smart albums and user albums appear empty except for those photos. This **breaks any "sort my whole library" flow**. Selection **persists** across launches until the user changes it. Prompt expansion via `PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:)` (iOS 15+). Set Info.plist `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES` to suppress the once-per-launch system prompt.

**SwipeSort decision:** request full `.readWrite` access. Personal-use app on user's own device — no reason to limit.

---

## 3. Feature Gaps (Non-Negotiables Even for Personal Use)

Ranked by how much they'd annoy the user (you) day-to-day:

1. **Session persistence across app kills / updates / reinstalls.** Nothing worse than re-swiping 30k photos. Persist "already reviewed" flag per `asset.localIdentifier`.
2. **Undo (last N swipes).** Fat-finger swipes happen. Minimum: undo last one. Better: review-before-commit queue.
3. **"Already reviewed" markers** on albums / months so you can see progress.
4. **Actually delete from Photos** — verify with visual inspection that deleted assets are gone from Photos app (not just marked in-app).
5. **Full-res pinch zoom** — sometimes you need to see the photo before deciding.
6. **Live Photos autoplay OFF by default** — waiting for a 1s animation before every swipe kills flow.
7. **Batch filter/sort:** date range, media type, size — "show me biggest videos" is huge for cleanup.

Deferred for later versions (or dropped entirely):
- Multi-device sync (personal use, one device)
- Sharing/AirDrop from within app (use iOS share sheet)
- Family Sharing edge cases
- Duplicate/similar AI detection (complex, not v1)
- Marketing polish, onboarding, paywalls `[deploy-only]`

---

## 4. Performance Gotchas (50k-100k+ libraries)

### 4.1 PHFetchResult

**Never convert `PHFetchResult<PHAsset>` to `[PHAsset]`.** It's a lazy cursor. Iterate via `object(at:)` / `enumerateObjects`. Converting materializes everything → OOM crash. ([WWDC14 Session 511](https://developer.apple.com/videos/play/wwdc2014/511/))

### 4.2 PHCachingImageManager

One instance per swipe view. Cache a window of ~5 ahead / 2 behind the current index.

- `targetSize` **in pixels**: `CGSize(width: cardW * UIScreen.main.scale, height: cardH * scale)`. Point/pixel mismatch = cache miss + double decode.
- `contentMode: .aspectFill`
- `options.deliveryMode = .opportunistic`, `.resizeMode = .fast` for cards, `.exact` only for detail view
- `options.isNetworkAccessAllowed = true` with `progressHandler` for iCloud
- `allowsCachingHighQualityImages = false`
- On every swipe: `startCachingImages(for: newlyInWindow, ...)` + `stopCachingImages(for: leftWindow, ...)` — **all four parameters must match exactly** across start/stop or the cache doubles.
- `stopCachingImagesForAllAssets()` on view disappear.

Docs: [PHCachingImageManager](https://developer.apple.com/documentation/photokit/phcachingimagemanager).

### 4.3 Video autoplay in swipe stack

- **Pool of 3 `AVPlayer` instances** (prev/current/next). NOT `AVQueuePlayer` — swipes are non-linear.
- Per item: `preferredForwardBufferDuration = 5`, `preferredPeakBitRate = 2_000_000`, `automaticallyWaitsToMinimizeStalling = false`, `isMuted = true`.
- Preload with `AVURLAsset` async: `try await asset.load(.isPlayable, .duration, .tracks)`.
- **Only the visible card calls `.play()`.** Neighbors are prepared but paused.
- On eviction: `player.replaceCurrentItem(with: nil)`, remove KVO / time observers **before** deinit or crash.
- Decoder ceiling ~4-5 concurrent H.264/HEVC decoders on older devices.
- For videos >30s: prefer thumbnail + play button over autoplay.

### 4.4 Live Photos

`PHImageManager.requestLivePhoto(...)` on card appear with a size **hint**; reserve full playback for explicit long-press. Never autoplay `.full` on swipe. Cancel in-flight `PHImageRequestID` on swipe. Cap in-memory `PHLivePhoto` count at 3 in a small `NSCache`.

### 4.5 First-launch indexing

`PHAsset.fetchAssets(with:)` itself is fast — it's a metadata cursor. Heavy work only if you're building your own index (e.g., perceptual hashes for dupes). Do it in a background `OperationQueue` at `.utility` QoS, persist to Core Data / SQLite, resume on relaunch. Never block launch on a full scan.

### 4.6 PHPhotoLibraryChangeObserver

Fires on **background queue**. Always:
```swift
guard let changes = changeInstance.changeDetails(for: fetchResult) else { return }
DispatchQueue.main.async {
    self.fetchResult = changes.fetchResultAfterChanges  // ALWAYS replace
    if changes.hasIncrementalChanges {
        // Apply removedIndexes / insertedIndexes to swipe stack.
        // If current index was removed, advance to next surviving asset.
    } else {
        self.cachingManager.stopCachingImagesForAllAssets()
        // Rebuild window from current position.
    }
}
```
If the current card is in `removedIndexes` (deleted externally by Photos.app or iCloud sync), snap forward. Requesting an image for a dead `localIdentifier` will crash.

---

## 5. Critical Design Decisions Locked In

1. **Full `.readWrite` PhotoKit access** — no limited-access UX.
2. **Batch delete at session commit** — build a decision queue in memory; user reviews; single `deleteAssets` call → single system prompt.
3. **Dry-run mode toggle** — never nuke real photos while iterating on delete logic. Ship a debug flag that logs decisions instead of deleting.
4. **In-memory session state & PhotoKit synchronization** — session decisions live in an observable `DecisionQueue` rather than a local SwiftData DB, keeping the app strictly in sync with the native PhotoKit library state.
5. **Protocol-boundary PhotoKit** — every PhotoKit call goes through a `PhotoLibraryProviding` protocol so tests can mock without touching the real library.
6. **iOS 17+ target** — Swift Testing (`import Testing`) and `@Observable` macro are enabled with this floor.
