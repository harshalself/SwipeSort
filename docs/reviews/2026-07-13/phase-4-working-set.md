# Phase 4 — Performance & Memory: Working Set (Re-Verified 2026-07-15)

Re-verified against current code after Phases 1–3 landed.

## Summary of verification

Original performance findings: F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14 (F1 was refuted during original review).
Phase 3 changed the most relevant files: `RecentsView` was simplified to a thin wrapper around `PhotoGridView`; `AlbumsView.swift` now holds both `AlbumsView` and `AlbumGridView`; `GridImageCache` moved to `Features/Components/GridImageCache.swift`; `PhotoGridView` is a new `Features/Components/PhotoGridView.swift`; `ThumbnailCell` moved to `Features/Components/ThumbnailCell.swift`. Line numbers across all affected files have shifted materially.

---

## Confirmed live findings

### W1 — Library-change notification triggers unbounced `loadAssets` / `loadAlbums` in `RecentsView` and `AlbumsView` (original F2)

- **File:** `SwipeSort/Features/Landing/RecentsView.swift:126–128` (was RecentsView.swift:238–240) and `SwipeSort/Features/Landing/AlbumsView.swift:101–103` (was AlbumsView.swift:98–100)
- **Severity:** high
- **Symptom:** Every `PHPhotoLibraryChangeObserver` notification immediately spawns `Task { await loadAssets() }` / `Task { await loadAlbums() }` with zero debounce or coalescing.
- **Current code state:**
  - `RecentsView.swift` line 126: `.onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in Task { await loadAssets() } }`
  - `AlbumsView.swift` line 101: identical pattern firing `loadAlbums()`.
  - `AlbumGridView` (inside AlbumsView.swift) line 243–245: third unbounced subscriber firing `loadAssets()`.
- **Failure scenario:** During iCloud sync the Photos daemon fires dozens of change notifications in rapid succession (one per downloaded asset). Each fires `loadAssets()` on both `RecentsView` and `AlbumGridView` when both tabs are in the responder tree, causing repeated `refreshFetchResult` + `applyFilter` + `identifiers(in:)` cycles — a full re-index per notification with no coalescing. A 50k-asset library re-index is a non-trivial Photos DB query.
- **Fix direction:** Wrap the `Task { await loadAssets() }` body in a debounce: store a `Task?` in `@State`, cancel any in-flight task before spawning the new one, and insert a `try await Task.sleep(for: .milliseconds(500))` at the top so only the last notification in a burst drives an actual re-index. Apply in all three `onReceive` sites (RecentsView, AlbumsView.loadAlbums, AlbumGridView.loadAssets).

---

### W2 — `WindowedThumbnailCache` window (5 ahead + 2 behind = 7 assets) is too narrow for drag-jump navigation (original F3)

- **File:** `SwipeSort/Core/WindowedThumbnailCache.swift:40–42` (was 25–27)
- **Severity:** high
- **Symptom:** Default `aheadOf: 5, behind: 2`; each `slide()` resolves identifiers via `library.identifiers(in:)` — a Photos DB round-trip.
- **Current code state:** `init(library:aheadOf:behind:targetSize:)` at line 39–47 with defaults `aheadOf: 5, behind: 2`. The `slide(to:total:)` logic at lines 53–88 is correct delta-only logic, but the default window size has not changed from the original review's findings.
- **Failure scenario:** A user flicks through 20 cards in 2 seconds issues 20 `slide()` calls. Each call incurs up to two `library.identifiers(in:)` round-trips (one for `toStart`, one for `toStop`), totalling up to 40 Photos DB queries in 2 seconds. At 50k assets, each round-trip has non-trivial latency. The cache lags behind the visible card.
- **Fix direction:** Increase the defaults to `aheadOf: 10, behind: 5`. Add a hysteresis guard: skip the slide entirely if `currentIndex` is already within the `currentWindow` (the new index is already cached), avoiding spurious stop/start pairs for single-card advances. The existing `Set`-difference logic remains correct; only the window width and the in-window no-op guard need changing.

---

### W3 — `GridImageCache.store(_:for:)` cost uses point-size pixels, understating actual memory by up to 9× on 3× retina devices (original F4)

- **File:** `SwipeSort/Features/Components/GridImageCache.swift:33` (was RecentsView.swift:28–30)
- **Severity:** high
- **Symptom:** `let cost = Int(image.size.width * image.size.height) * 4` — `UIImage.size` is in points, not pixels.
- **Current code state confirmed:** line 33 of `GridImageCache.swift` reads `let cost = Int(image.size.width * image.size.height) * 4` — unchanged from the original. File moved from `RecentsView.swift` to `GridImageCache.swift` by Phase 3; the bug moved with it.
- **Failure scenario:** A 3× device requesting 400×400px thumbnails receives images with `UIImage.size = 133×133` points. Stored cost = `133*133*4 ≈ 70 KB` when true footprint is `400*400*4 = 640 KB`. `totalCostLimit = 80 MB` is effectively 9× too permissive; the cache silently grows to ~384 MB before `countLimit = 600` evicts, triggering OS memory pressure and `didReceiveMemoryWarning`.
- **Fix direction:** Replace `image.size.width/height` with `image.cgImage?.width ?? Int(image.size.width)` and `image.cgImage?.height ?? Int(image.size.height)` (which return pixel dimensions regardless of scale), or multiply by `image.scale`. Prefer `cgImage` dimensions since they reflect the actual allocated buffer size.

---

### W4 — `VideoPlayerPool.drain()` is only called from `SwipeStackView.onDisappear`; sheet dismissals that bypass `onDisappear` leak retained `AVPlayer` instances (original F5)

- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:106–109` (was 102–105) and `SwipeSort/Core/VideoPlayerPool.swift:78–84` (was 67–73)
- **Severity:** high
- **Symptom:** `VideoPlayerPool.shared.drain()` is the only drain path; it is called only in `onDisappear`.
- **Current code state:** `onDisappear` at lines 106–109 calls `thumbnailCache?.stopAll()` and `VideoPlayerPool.shared.drain()`. There is no drain in any model phase-transition path, no `deinit` drain, and no drain wired to `model.phase == .finished`.
- **Failure scenario:** The user opens `FullResViewer` (line 110–112) as a `.sheet` from within `SwipeStackView`. If the user navigates away from the app while the sheet is open, `SwipeStackView.onDisappear` does not fire (the parent is backgrounded, not deallocated). The `VideoPlayerPool.shared` retains up to 3 `AVPlayer` instances indefinitely across navigation sessions until the next `onDisappear` fires.
- **Fix direction:** Add a `VideoPlayerPool.shared.drain()` call in the `.onChange(of: model.phase)` handler when `newPhase == .finished`, so the pool is always drained when the session ends regardless of the dismissal route. Alternatively, make the pool session-scoped (passed into `SwipeStackView`) so it is freed with the view's `@State`.

---

### W5 — `RecentsView.loadAssets` calls `refreshFetchResult` then `applyFilter` unconditionally, causing two cursor invalidations when the filter is unchanged (original F6)

- **File:** `SwipeSort/Features/Landing/RecentsView.swift:136–137` (was 244–254) and `SwipeSort/Features/Landing/AlbumsView.swift:250–251` (was 319–320)
- **Severity:** high
- **Symptom:** `loadAssets()` always calls `library.refreshFetchResult()` then `library.applyFilter(filter)` in sequence.
- **Current code state confirmed:**
  - `RecentsView.loadAssets()` at lines 136–137: `await library.refreshFetchResult()` then `await library.applyFilter(filter)`.
  - `AlbumGridView.loadAssets()` at lines 250–251: `await s.refreshFetchResult()` then `await s.applyFilter(filter)`.
  - `PhotoKitLibrary.refreshFetchResult()` (line 503–508) unconditionally sets `fetchResult = nil`.
  - `PhotoKitLibrary.applyFilter()` (line 510–519) guards `filter != activeFilter` before acting. When filter is unchanged, `applyFilter` returns without re-invalidating — but `refreshFetchResult` already nilledthe cursor, so `ensureFetchResult()` will re-run the DB query regardless.
- **Failure scenario:** On every library-change notification (with no debounce — W1), two actor hops + one unconditional cursor nil + one guard check + one DB re-query happen in sequence. With rapid iCloud sync events the result is back-to-back re-indexes where a single `refreshFetchResult` (without the redundant `applyFilter`) would suffice.
- **Fix direction:** Remove the unconditional `refreshFetchResult()` call from `loadAssets`. Instead, always call only `applyFilter(filter)`. Modify `applyFilter` to unconditionally invalidate the cursor (not just on filter change) so that the library-change path is covered. Alternatively, add a separate `forceRefresh: Bool` parameter to `applyFilter` that bypasses the equality guard when called from the notification path.

---

### W6 — `SwipeStackView.task` block has no `Task.isCancelled` checkpoints between major `await` calls (original F7)

- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:87–97` (was 83–93)
- **Severity:** medium
- **Symptom:** The `.task { }` block calls `library.applyFilter`, `model.start()`, `library.userAlbums()`, and `thumbnailCache?.slide()` in a linear sequence with no `Task.isCancelled` checks.
- **Current code state confirmed:** lines 87–97 have the same structure as the original review found. No `try Task.checkCancellation()` or `guard !Task.isCancelled` anywhere in the `.task` body.
- **Failure scenario:** User opens the swipe deck then immediately taps `×`. The `.task` modifier cancels the Swift task, but only at the next cooperative suspension point. `model.start()` calls `library.assetCount()` and `library.identifiers(in:)` — Photos DB round-trips — which run to completion even after the view is gone. `library.userAlbums()` enumerates all albums (O(albums × assetCount queries)); on a library with 200 albums this is pure wasted work on a dismissed view.
- **Fix direction:** Add `guard !Task.isCancelled else { return }` between each major `await` in the `.task` body — after `applyFilter`, after `model.start()`, after `userAlbums()`. This allows cooperative early exit without requiring changes to PhotoKit's non-cancellation-aware callback APIs.

---

### W7 — `SwipeStackView.init` captures `cardPixelSize` from `UITraitCollection.current.displayScale` before the view is attached to a display (original F8)

- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:51–53` (was 47–48)
- **Severity:** medium
- **Symptom:** `PixelSize.from(points:)` is called during `init`, which executes before the view is attached to a screen; `UITraitCollection.current.displayScale` may return `1.0` at that point.
- **Current code state confirmed:** lines 51–53: `let target = PixelSize.from(points: CGSize(width: 400, height: 600))` and `_model = State(initialValue: SwipeSessionModel(..., targetSize: target))`. `PixelSize.swift` line 15 reads `UITraitCollection.current.displayScale` as the default argument — evaluated at call time, which is during `init`. `@State(initialValue:)` in `init` runs before the view is mounted.
- **Failure scenario:** On a 3× iPhone where `UITraitCollection.current.displayScale` reads as `1.0` at init time, `cardPixelSize` is `400×600` points instead of `1200×1800` pixels. All swipe card thumbnails are requested at 400×600 — displayed at 1200×1800 physical pixels — producing blurry cards for the entire session. The `WindowedThumbnailCache` also receives the wrong `targetSize`, so every caching start/stop call uses undersized parameters.
- **Fix direction:** Move `cardPixelSize` computation out of `init` and into the `.task` block (where `UITraitCollection.current` reflects the actual display), or use `UIScreen.main.scale` which is available pre-attachment. Pass the resolved `targetSize` to `SwipeSessionModel` via a separate `configure(targetSize:)` method called from `.task`. Alternatively, read `\.pixelLength` from the SwiftUI environment (the modern iOS 17+ replacement for `UIScreen.main.scale`) inside `.task`.

---

### W8 — `WindowedThumbnailCache.resolveIdentifiers` fetches a contiguous span that over-includes indices between sparse non-adjacent positions (original F9)

- **File:** `SwipeSort/Core/WindowedThumbnailCache.swift:104–116` (was 80–92)
- **Severity:** medium
- **Symptom:** `resolveIdentifiers(at:)` fetches `library.identifiers(in: first..<(last+1))` — a contiguous range from min to max — even when the `indices` array is sparse.
- **Current code state confirmed:** lines 104–116 of `WindowedThumbnailCache.swift`: `let batch = await library.identifiers(in: first..<(last + 1))`. This is unchanged from the original finding.
- **Failure scenario:** After an `undo()` that walks back 20 positions, `toStop` and `toStart` can be non-contiguous index sets with a span of 20+. `resolveIdentifiers` fetches the full 20-index span to retrieve the 5–7 actually needed. Compounded with W1 (unbounced notifications) and W2 (narrow window causing frequent re-slides), cumulative Photos DB query pressure is meaningful on 50k-asset libraries.
- **Fix direction:** For sparse index sets (where `last - first + 1 > indices.count * 2`), batch into multiple small contiguous fetches rather than one large span fetch. For the common dense case (consecutive window slides), the current contiguous fetch is optimal and should be preserved.

---

### W9 — `GridImageCache.kinds` dictionary is unbounded; stale entries accumulate across filter changes (original F10)

- **File:** `SwipeSort/Features/Components/GridImageCache.swift:23` (was RecentsView.swift:21, 35–39)
- **Severity:** medium
- **Symptom:** `kinds: [String: MediaKind]` has no size cap and is never cleared between filter changes.
- **Current code state confirmed:** `GridImageCache.swift` line 23: `private var kinds: [String: MediaKind] = [:]`. No eviction, no cap, no reset on filter change. File moved to `Components/` by Phase 3 but the unbounded `kinds` dictionary moved with it.
- **Failure scenario:** `RecentsView` and `AlbumGridView` each hold a `GridImageCache` in `@State`. After the user changes filters several times, the `kinds` dictionary accumulates stale `MediaKind` entries from previous filter sets that are no longer in the visible `assetIds`. With 1,000 entries the footprint is small (~40 KB), but the unbounded growth is architecturally inconsistent with the `NSCache` approach for images, and the stale entries are dead weight on every filter change.
- **Fix direction:** After each `loadAssets()` call, trim the `kinds` dictionary to the current `assetIds` set: `kinds = kinds.filter { assetIds.contains(AssetIdentifier($0.key)) }`. Alternatively, expose a `reset(keeping:)` method on `GridImageCache` that the parent view calls after a filter change. This is low-effort and ensures the dictionary stays bounded to the active asset set.

---

### W10 — `WindowedThumbnailCache.stopAll()` in `onDisappear` can race with a concurrent `slide()` task queued just before disappear (original F11)

- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:106–109` (was 102–105) and `SwipeSort/Core/WindowedThumbnailCache.swift:93–96` (was 71–74)
- **Severity:** medium
- **Symptom:** `onDisappear` calls `thumbnailCache?.stopAll()` synchronously while a `Task { await thumbnailCache?.slide(...) }` spawned by `onChange(of: model.currentIndex)` may be queued and not yet started.
- **Current code state confirmed:** `SwipeStackView.swift` line 104: `Task { await thumbnailCache?.slide(to: newIndex, total: model.totalCount) }`. Line 107: `thumbnailCache?.stopAll()`. No stored `Task` handle, no cancellation before `stopAll()`.
- **Failure scenario:** A rapid swipe just before the user taps `×` queues a `slide()` Task. `onDisappear` fires synchronously, calls `stopAll()`, resets `currentWindow = 0..<0`. Milliseconds later the queued `slide()` task resumes, computes a diff against the empty `currentWindow`, and calls `startCachingImages` on the new window. The cache is left running after the view is gone, until the next `onDisappear` — which never comes.
- **Fix direction:** Store the slide task in `@State private var slideTask: Task<Void, Never>?`. In `onChange(of: model.currentIndex)`, assign `slideTask = Task { await thumbnailCache?.slide(...) }`. In `onDisappear`, call `slideTask?.cancel(); slideTask = nil` before `thumbnailCache?.stopAll()`. Since both run on `@MainActor`, the cancel and stopAll execute in the same actor turn.

---

### W11 — iCloud download progress is not surfaced to the user; `thumbnail(for:)` silently returns `nil` on iCloud failure with no retry path (original F12)

- **File:** `SwipeSort/Core/PhotoKitLibrary.swift:86–142` (was 65–120)
- **Severity:** medium
- **Symptom:** `PHImageRequestOptions` has no `progressHandler`; iCloud download failures return `nil` silently to callers.
- **Current code state confirmed:** `PhotoKitLibrary.thumbnail(for:targetSize:)` at lines 86–142: `options.isNetworkAccessAllowed = true` but no `progressHandler` set. On failure the handler fires with `image == nil` and `PHImageErrorKey` set; the `resumeOnce(nil)` path fires and the method returns `nil` to the caller. `avPlayerItem(for:)` at lines 391–407 also has no `progressHandler`.
- **Failure scenario:** A user with an iCloud Photo Library on poor cellular signal sees blank swipe cards for every undownloaded asset. There is no spinner, no "Downloading from iCloud" text, and no retry. The user is stuck on a blank card until they manually swipe. For video assets, the `AVPlayerItem` is `nil` silently with no user feedback.
- **Fix direction:** Add a `progressHandler` to `PHImageRequestOptions` that publishes download progress (0.0–1.0) through a callback or `AsyncStream`. Expose an `@Published` / `@Observable` `isDownloading: Bool` on `ThumbnailCell` (or on a wrapper type returned from `thumbnail(for:)`) so the card view can show a `ProgressView`. Implement one automatic retry on failure (call `thumbnail(for:)` again after a short delay). The same pattern applies to `avPlayerItem(for:)`.

---

### W12 — `PhotoGridView.thumbnailPixelSize` is a hard-coded `400×400` point literal, not pixel-scaled (new finding — Phase 3 surface)

- **File:** `SwipeSort/Features/Components/PhotoGridView.swift:29`
- **Severity:** medium
- **Symptom:** `private let thumbnailPixelSize = CGSize(width: 400, height: 400)` is stored as a constant literal, bypassing `PixelSize.from(points:)`.
- **Current code state confirmed:** `PhotoGridView.swift` line 29 is a raw `CGSize(width: 400, height: 400)`. The field is named `thumbnailPixelSize` — implying pixel dimensions — but the value is actually 400×400 **points**. On a 3× device, cells request thumbnails at 400×400 instead of 1200×1200 pixels, producing blurry grid thumbnails. `GridImageCache` then caches these undersized images; even if the correct size were later requested, the cache would serve the undersized version.
- **Failure scenario:** On any 3× iPhone (all modern Pro and current base models), every grid thumbnail is requested at 1/9th the correct pixel count. The grid displays blurry thumbnails in both the Recents and Albums tabs for the lifetime of the `GridImageCache` (which is `@State` and survives for the app session).
- **Fix direction:** Replace the literal with `PixelSize.from(points: CGSize(width: 400, height: 400))`. Since `PhotoGridView.body` is evaluated on the main actor (and `PixelSize.from` is `@MainActor`), this is safe to call from `body` or from a `let` stored property initialized in an `onAppear` / `.task`. The cleanest approach: declare `private var thumbnailPixelSize: CGSize { PixelSize.from(points: CGSize(width: 400, height: 400)) }` as a computed property.

---

## Resolved incidentally

- **Original F6 "RecentsView.loadAssets refreshFetchResult + applyFilter":** the AlbumGridView half of this finding shifted files (now AlbumsView.swift:250–251) but the defect is still live; confirmed as W5 above. Not resolved.

- **Original F10 "GridImageCache.kinds unbounded":** file moved to `GridImageCache.swift` by Phase 3 but the `kinds` dictionary and its lack of eviction is identical; confirmed as W9 above. Not resolved.

- **Original F4 "GridImageCache NSCache cost understated":** file moved to `GridImageCache.swift` by Phase 3; the `image.size.width * image.size.height` bug moved with it; confirmed as W3 above. Not resolved.

No performance findings were resolved incidentally by Phases 1, 2, or 3.

---

## Newly surfaced by Phase 3

### N1 — `PhotoGridView.thumbnailPixelSize` hard-coded as point literal (W12 above)

Phase 3 extracted `PhotoGridView` as a new file. The `thumbnailPixelSize` constant was introduced during that extraction with a hard-coded `CGSize(width: 400, height: 400)` that skips `PixelSize.from(points:)`. This is a new defect introduced by Phase 3; it did not exist in the pre-Phase-3 `RecentsView.swift` (which did not have a separate `thumbnailPixelSize` constant — it passed the pixel size through from the parent). This finding is folded into the main confirmed-live list as W12.

---

## Ignored (out of scope for Phase 4)

- **Original F13 — AlbumGridView loads up to 1000 identifiers, RecentsView 500; no pagination:** severity is **low**; memory impact is ~64 KB, not measurable in production. The `ForEach` diff overhead is real but imperceptible. Pagination is a product scope decision, not a perf fix. Deferred to Phase 7 (cleanup scope). If surfaced in Phase 7, the fix is cursor-based pagination with a "showing first N of M" indicator.

- **Original F14 — VideoPlayerPool eviction does not cancel in-flight `PHImageManager` request IDs:** severity is **low**. The impact is limited to iCloud video downloads that continue in background after pool eviction. For standard local assets (the common case) `replaceCurrentItem(with: nil)` is sufficient. Deferred to Phase 7.

---

## Working set summary

- **W items (confirmed live):** W1–W12 = **12**
  - High severity: W1, W2, W3, W4, W5 = **5**
  - Medium severity: W6, W7, W8, W9, W10, W11, W12 = **7**
- **N items (newly surfaced by Phase 3):** 1 (folded into W12 above)
- **Total to fix in Phase 4: 12**

### Recommended fix order

1. **W3 + W12 (bundle)** — Both are one-line cost/size fixes; land together. `GridImageCache.store` pixel cost (W3) and `PhotoGridView.thumbnailPixelSize` literal (W12). No dependencies.
2. **W1** — Debounce the three `onReceive` notification handlers. No dependencies; unlocks W5 to be cleaner.
3. **W5** — Remove redundant `refreshFetchResult` call from `loadAssets`. Coordinate: `applyFilter` guard must be widened to cover the notification-refresh path, so land after W1 to verify the combined debounce + single-invalidation flow.
4. **W10** — Store `slideTask` and cancel before `stopAll()`. No dependencies; small and self-contained.
5. **W4** — Add `VideoPlayerPool.shared.drain()` to the `model.phase == .finished` path. No dependencies.
6. **W2** — Widen window defaults + in-window no-op guard. No dependencies.
7. **W8** — Sparse index batch splitting in `resolveIdentifiers`. No dependencies.
8. **W9** — Trim `kinds` dictionary to active `assetIds` after `loadAssets`. No dependencies.
9. **W6** — Add `Task.isCancelled` checkpoints to the `.task` body in `SwipeStackView`. No dependencies.
10. **W7** — Move `cardPixelSize` computation out of `init` into `.task`. Depends on `SwipeSessionModel` accepting a late `configure(targetSize:)` call.
11. **W11** — Add `progressHandler` and retry to `thumbnail(for:)` and `avPlayerItem(for:)`. Most complex; depends on defining the progress observation contract between `PhotoKitLibrary` and `ThumbnailCell`.
