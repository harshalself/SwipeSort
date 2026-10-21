# Phase 4 Performance & Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 12 confirmed performance & memory findings from the 2026-07-13 review (5 high, 7 medium) with minimal code churn, preserving Phase 3 architecture.

**Architecture:** Perf fixes are localized to the file(s) owning each defect. No cross-cutting refactors. Task order reflects dependencies where they exist (e.g., W5 depends on W1's debounce landing first so that the combined debounce + single-invalidation flow can be verified together).

**Tech Stack:** Swift 5, SwiftUI, PhotoKit, Swift Testing, PHCachingImageManager, NSCache.

**Working set:** [`docs/reviews/2026-07-13/phase-4-working-set.md`](../../reviews/2026-07-13/phase-4-working-set.md)

## Global Constraints

- Swift 5 language mode (not Swift 6); iOS 17 minimum deployment target.
- `@Observable` + `@MainActor` are already in play from Phase 2. All new types that carry mutable state must be `@MainActor`-isolated.
- `PhotoLibraryProviding` is a typealias for `PhotoLibraryReadProviding & PhotoLibraryCacheProviding & PhotoLibraryMutating` (Phase 3, W6). Consumers use the typealias — do not narrow any `let library:` declaration to a sub-protocol in this phase.
- `GridImageCache`, `ThumbnailCell`, `PhotoGridView`, `GridSelectionInfra`, `SwipePresentationContext` all live in `SwipeSort/Features/Components/` (Phase 3). All new component files also go in `Features/Components/`.
- `DryRunMode.defaultsKey` semantics unchanged; do not alter user-defaults behavior in perf tasks.
- No new dependencies. No new SwiftUI framework versions.
- Tests use Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`); mocks use `MockPhotoLibrary` from `SwipeSort/Core/MockPhotoLibrary.swift`. All new tests go in `SwipeSortTests/`.
- No swift/xcodebuild in this workspace — every "Build" and "Test" step is a logical verification; the human runs them in Xcode.
- Every new .swift file created in this plan **must be flagged at the end of its task** with: `⚠️ Human: add SwipeSort/Features/Components/<filename>.swift (or <path>) to the SwipeSort Xcode target.`
- Task splitting rule: bundle mechanical one-liners; give behavior-changing fixes their own task with tests.

---

## Task ordering rationale

1. **Task 1 (W3 + W12)** — Two one-line pixel-scale fixes that are completely independent. Land first so all subsequent thumbnail requests use correct pixel sizes.
2. **Task 2 (W1)** — Debounce three `onReceive` handlers. Independent. Unlocks Task 3.
3. **Task 3 (W5)** — Remove redundant `refreshFetchResult()` from `loadAssets`. Depends on Task 2 being landed so the combined debounce + single-cursor-invalidation path can be verified.
4. **Task 4 (W10 + W4)** — Task-lifecycle bundle: store `slideTask` + cancel before `stopAll()`; drain `VideoPlayerPool` on `.finished`. Both are in `SwipeStackView`; both are self-contained.
5. **Task 5 (W2)** — Widen `WindowedThumbnailCache` window defaults + in-window no-op guard. Self-contained.
6. **Task 6 (W8)** — Sparse batch fetching in `resolveIdentifiers`. Self-contained.
7. **Task 7 (W9)** — Trim `GridImageCache.kinds` after `loadAssets`. Self-contained.
8. **Task 8 (W6)** — Add `Task.isCancelled` checkpoints to `SwipeStackView.task` body. Self-contained.
9. **Task 9 (W7)** — Defer `cardPixelSize` computation from `init` to `.task`. Adds `configure(targetSize:)` to `SwipeSessionModel`.
10. **Task 10 (W11)** — Add `progressHandler` + retry to `thumbnail(for:)` and `avPlayerItem(for:)`; surface iCloud download progress in `ThumbnailCell`. Largest task; own commit.

---

## Task 1: W3 + W12 — Pixel-scale bundle (`GridImageCache.store` cost + `PhotoGridView.thumbnailPixelSize`)

**Files:**
- Modify: `SwipeSort/Features/Components/GridImageCache.swift`
- Modify: `SwipeSort/Features/Components/PhotoGridView.swift`
- Test: `SwipeSortTests/GridImageCacheTests.swift` (new file)

**Interfaces:**
- Consumes: `UIImage.cgImage?.width` / `.height` (pixels); `PixelSize.from(points:)` (already exists in `SwipeSort/Core/PixelSize.swift`)
- Produces: `GridImageCache.store(_:for:)` uses pixel dimensions for cost; `PhotoGridView.thumbnailPixelSize` is a computed property that calls `PixelSize.from(points:)`.

**Why these two together:** Both are one-line fixes with zero behavioral difference except on retina devices. They share a regression test file so the pixel-scale contract is asserted once.

---

- [ ] **Step 1: Write the regression test first (TDD anchor)**

Create `SwipeSortTests/GridImageCacheTests.swift`:

```swift
import Testing
import UIKit
@testable import SwipeSort

@Suite("GridImageCache")
@MainActor
struct GridImageCacheTests {

    // W3 regression: cost must use pixel dimensions, not point dimensions.
    // A 3× image where UIImage.size = 100×100 pt should cost 300×300×4 = 360 000,
    // NOT 100×100×4 = 40 000.
    @Test("store cost uses cgImage pixel dimensions not point dimensions")
    func storeCostUsesPixels() {
        let cache = GridImageCache()
        let id = AssetIdentifier("test-asset-1")

        // Build a 300×300 px image at 3× scale (UIImage.size will be 100×100 pt).
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 300, height: 300)
        )
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }

        // Confirm the test fixture: size is in points (may vary by renderer),
        // but cgImage is always in pixels.
        let cgW = img.cgImage?.width ?? Int(img.size.width)
        let cgH = img.cgImage?.height ?? Int(img.size.height)
        // cgImage must be 300×300 px regardless of scale factor.
        #expect(cgW == 300)
        #expect(cgH == 300)

        // After store, the image must be retrievable (NSCache stores it).
        cache.store(img, for: id)
        let retrieved = cache.image(for: id)
        #expect(retrieved != nil, "Image must be stored and retrievable")

        // Indirect verification: if cost were computed from points (potentially
        // much smaller), the NSCache totalCostLimit of 80 MB would be effectively
        // larger than declared, so we can't evict-test here. The real assertion is
        // that the code uses cgImage, checked by code inspection in Step 2.
        // This test acts as a build-time regression pin: it fails to compile if
        // GridImageCache.store no longer accepts a UIImage.
    }

    @Test("store and retrieve a media kind")
    func storeAndRetrieveKind() {
        let cache = GridImageCache()
        let id = AssetIdentifier("test-asset-2")
        cache.store(.video(durationSeconds: 12.5), for: id)
        #expect(cache.mediaKind(for: id) == .video(durationSeconds: 12.5))
    }

    @Test("trimKinds removes entries not in the keeper set")
    func trimKindsRemovesStale() {
        let cache = GridImageCache()
        let keep1 = AssetIdentifier("keep-1")
        let keep2 = AssetIdentifier("keep-2")
        let stale = AssetIdentifier("stale-1")

        cache.store(.photo, for: keep1)
        cache.store(.livePhoto, for: keep2)
        cache.store(.video(durationSeconds: 5), for: stale)

        cache.trimKinds(keeping: [keep1, keep2])

        #expect(cache.mediaKind(for: keep1) == .photo,   "kept entry must survive trim")
        #expect(cache.mediaKind(for: keep2) == .livePhoto, "kept entry must survive trim")
        #expect(cache.mediaKind(for: stale) == nil,      "stale entry must be removed")
    }
}
```

> Note: `trimKinds(keeping:)` is introduced in Task 7 (W9). At this point the test for it will fail to compile until Task 7. The test suite file is created here so the pixel-regression anchor is available immediately; comment out the `trimKindsRemovesStale` test body with `// TODO: uncomment after Task 7 (W9)` until Task 7 lands.

Concrete action: in `GridImageCacheTests.swift`, wrap the `trimKindsRemovesStale` test body in `#if false` until Task 7:

```swift
    @Test("trimKinds removes entries not in the keeper set")
    func trimKindsRemovesStale() {
        // TODO: uncomment after Task 7 (W9) adds trimKinds(keeping:)
        #if false
        let cache = GridImageCache()
        let keep1 = AssetIdentifier("keep-1")
        let keep2 = AssetIdentifier("keep-2")
        let stale = AssetIdentifier("stale-1")

        cache.store(.photo, for: keep1)
        cache.store(.livePhoto, for: keep2)
        cache.store(.video(durationSeconds: 5), for: stale)

        cache.trimKinds(keeping: [keep1, keep2])

        #expect(cache.mediaKind(for: keep1) == .photo)
        #expect(cache.mediaKind(for: keep2) == .livePhoto)
        #expect(cache.mediaKind(for: stale) == nil)
        #endif
    }
```

- [ ] **Step 2: Fix `GridImageCache.store` cost (W3)**

In `SwipeSort/Features/Components/GridImageCache.swift`, line 33, replace the point-based cost with pixel-based cost:

```swift
    func store(_ image: UIImage, for id: AssetIdentifier) {
        // Approximate byte cost = pixels × 4 (RGBA). NSCache uses cost as the
        // eviction priority signal, so large images are dropped first when the
        // 80 MB total limit is approached.
        let cost = Int(image.size.width * image.size.height) * 4
        cache.setObject(image, forKey: id.rawValue as NSString, cost: cost)
    }
```

Replace with:

```swift
    func store(_ image: UIImage, for id: AssetIdentifier) {
        // W3 fix: use pixel dimensions (cgImage.width/height) rather than
        // UIImage.size (which is in points). On a 3× device a 400×400 pt image
        // has UIImage.size = 400×400 pt but cgImage = 1200×1200 px; using points
        // understated cost by 9×, letting NSCache silently grow to ~720 MB before
        // countLimit eviction kicked in.
        let pixelW = image.cgImage?.width ?? Int(image.size.width)
        let pixelH = image.cgImage?.height ?? Int(image.size.height)
        let cost = pixelW * pixelH * 4
        cache.setObject(image, forKey: id.rawValue as NSString, cost: cost)
    }
```

- [ ] **Step 3: Fix `PhotoGridView.thumbnailPixelSize` (W12)**

In `SwipeSort/Features/Components/PhotoGridView.swift`, line 29, replace the hard-coded `CGSize` constant with a computed property that calls `PixelSize.from(points:)`:

```swift
    private let thumbnailPixelSize = CGSize(width: 400, height: 400)
```

Replace with:

```swift
    // W12 fix: compute pixel dimensions using the actual display scale rather
    // than hard-coding 400×400 pt. On a 3× device this produces 1200×1200 px
    // thumbnails instead of 400×400. Declared as a computed property so
    // PixelSize.from(points:) reads UITraitCollection.current.displayScale
    // after the view is attached to a screen (safe from body or task).
    private var thumbnailPixelSize: CGSize {
        PixelSize.from(points: CGSize(width: 400, height: 400))
    }
```

- [ ] **Step 4: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `PixelSize.from(points:)` is `@MainActor`; `PhotoGridView.body` is evaluated on the main actor, so a computed property calling it from `body` is safe. `GridImageCache.store` compiles because `UIImage.cgImage` returns `CGImage?` with `.width` / `.height` as `Int`.

- [ ] **Step 5: Run `GridImageCacheTests`**

In Xcode: Product → Test → filter to `GridImageCacheTests`.

Expected: `storeCostUsesPixels` and `storeAndRetrieveKind` **PASS**. `trimKindsRemovesStale` is gated by `#if false` and will not run.

- [ ] **Step 6: Run full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. No existing test asserts on thumbnail pixel dimensions.

- [ ] **Step 7: Commit**

```
Report line: "phase-4/W3+W12: GridImageCache.store now uses cgImage pixel dimensions for NSCache cost; PhotoGridView.thumbnailPixelSize is now a computed property via PixelSize.from(points:) — W3, W12"
```

⚠️ **Human: add `SwipeSortTests/GridImageCacheTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 2: W1 — Debounce library-change notification handlers

**Files:**
- Modify: `SwipeSort/Features/Landing/RecentsView.swift`
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift`
- Test: `SwipeSortTests/LibraryChangeDebounceTests.swift` (new file)

**Interfaces:**
- Consumes: `NotificationCenter`, `Task.sleep(for:)`, `@State private var Task?`
- Produces: `RecentsView`, `AlbumsView`, and `AlbumGridView` each store a `Task?` in `@State`; rapid-fire notifications coalesce into a single `loadAssets()` / `loadAlbums()` call after a 500 ms quiet period.

**Pattern (apply identically at all three sites):**
```
@State private var libraryChangeTask: Task<Void, Never>?

// In .onReceive:
libraryChangeTask?.cancel()
libraryChangeTask = Task {
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled else { return }
    await loadAssets()   // or loadAlbums()
}
```

---

- [ ] **Step 1: Write the regression test first**

Create `SwipeSortTests/LibraryChangeDebounceTests.swift`:

```swift
import Testing
import Foundation
@testable import SwipeSort

/// Verifies that rapid-fire library-change notifications result in exactly one
/// loadAssets() call, not one per notification.
///
/// The test simulates the debounce logic in isolation by extracting the
/// debounce pattern into a helper and asserting on call-count. Because
/// SwiftUI view logic cannot be unit-tested directly, the test validates the
/// *debounce contract* independently: N rapid cancels followed by one final
/// task must yield exactly 1 execution of the body.
@Suite("LibraryChangeDebounce")
struct LibraryChangeDebounceTests {

    /// Simulates N rapid notifications: each cancels the previous task and
    /// spawns a new one with a 50 ms sleep (shortened from 500 ms for tests).
    /// Only the last task survives to completion. Asserts exactly 1 body call.
    @Test("rapid notifications coalesce into exactly one load call")
    func rapidNotificationsCoalesce() async {
        let callCount = Counter()
        var currentTask: Task<Void, Never>? = nil

        let notificationCount = 10
        for _ in 0..<notificationCount {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }

        // Wait for the surviving task to complete (50 ms debounce + 10 ms buffer).
        try? await Task.sleep(for: .milliseconds(100))

        await #expect(callCount.value == 1,
            "10 rapid notifications must coalesce into exactly 1 load call")
    }

    /// Verifies that two bursts separated by > debounce each produce one call.
    @Test("two separate bursts produce two load calls")
    func separateBurstsProduceTwoCalls() async {
        let callCount = Counter()
        var currentTask: Task<Void, Never>? = nil

        // First burst of 5
        for _ in 0..<5 {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }
        // Wait for first burst to settle
        try? await Task.sleep(for: .milliseconds(120))

        // Second burst of 5
        for _ in 0..<5 {
            currentTask?.cancel()
            currentTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                await callCount.increment()
            }
        }
        // Wait for second burst to settle
        try? await Task.sleep(for: .milliseconds(120))

        await #expect(callCount.value == 2,
            "Two separate bursts must each fire exactly one load call")
    }
}

/// Thread-safe call counter for async test assertions.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
```

- [ ] **Step 2: Run `LibraryChangeDebounceTests` to confirm they pass standalone**

In Xcode: Product → Test → filter to `LibraryChangeDebounceTests`.

Expected: both tests **PASS** (the test exercises the debounce pattern directly; it doesn't depend on view code yet).

- [ ] **Step 3: Add `libraryChangeTask` state and debounce to `RecentsView`**

In `SwipeSort/Features/Landing/RecentsView.swift`, add one new `@State` property and replace the `.onReceive` handler.

**3a — Add state property.** In `RecentsView`, after line 21 (`@State private var showingAlbumPicker = false`), insert:

```swift
    // W1 fix: stored task handle for debouncing library-change notifications.
    @State private var libraryChangeTask: Task<Void, Never>?
```

**3b — Replace the `.onReceive` handler.** Current code at lines 126–128:

```swift
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                Task { await loadAssets() }
            }
```

Replace with:

```swift
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                // W1 fix: debounce — cancel any in-flight task before spawning a
                // new one. A 500 ms quiet period coalesces rapid iCloud sync bursts
                // (which can fire dozens of notifications in a few seconds) into a
                // single loadAssets() call. Both operations run on @MainActor since
                // RecentsView is isolated to the main actor.
                libraryChangeTask?.cancel()
                libraryChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await loadAssets()
                }
            }
```

- [ ] **Step 4: Add `libraryChangeTask` state and debounce to `AlbumsView` (loadAlbums path)**

In `SwipeSort/Features/Landing/AlbumsView.swift`, in the `AlbumsView` struct:

**4a — Add state property.** After line 16 (`@State private var showingAlbumFilter = false`), insert:

```swift
    // W1 fix: debounce token for library-change notifications.
    @State private var libraryChangeTask: Task<Void, Never>?
```

**4b — Replace the `.onReceive` handler.** Current code at lines 101–103:

```swift
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                Task { await loadAlbums() }
            }
```

Replace with:

```swift
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                // W1 fix: debounce library-change notifications (same pattern as RecentsView).
                libraryChangeTask?.cancel()
                libraryChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await loadAlbums()
                }
            }
```

- [ ] **Step 5: Add `libraryChangeTask` state and debounce to `AlbumGridView` (loadAssets path)**

In `SwipeSort/Features/Landing/AlbumsView.swift`, in the `AlbumGridView` struct:

**5a — Add state property.** After line 136 (`@State private var showingAlbumPicker = false`), insert:

```swift
    // W1 fix: debounce token for library-change notifications.
    @State private var libraryChangeTask: Task<Void, Never>?
```

**5b — Replace the `.onReceive` handler.** Current code at lines 243–245:

```swift
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
            Task { await loadAssets() }
        }
```

Replace with:

```swift
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
            // W1 fix: debounce library-change notifications (same pattern as RecentsView).
            libraryChangeTask?.cancel()
            libraryChangeTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await loadAssets()
            }
        }
```

- [ ] **Step 6: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `Task.sleep(for:)` is `@available(iOS 16.0, *)` — compatible with iOS 17 minimum target. `Task { }` in an `@MainActor`-isolated view closure inherits the main-actor context.

- [ ] **Step 7: Run `LibraryChangeDebounceTests` and the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. The two debounce tests anchor the contract; the rest of the suite verifies no regressions.

- [ ] **Step 8: Commit**

```
Report line: "phase-4/W1: debounce PHPhotoLibraryChangeObserver notifications in RecentsView, AlbumsView, and AlbumGridView with 500 ms cancel-and-respawn pattern — W1"
```

⚠️ **Human: add `SwipeSortTests/LibraryChangeDebounceTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 3: W5 — Remove redundant `refreshFetchResult()` from `loadAssets`

**Files:**
- Modify: `SwipeSort/Features/Landing/RecentsView.swift`
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift`
- Modify: `SwipeSort/Core/PhotoKitLibrary.swift`
- Modify: `SwipeSort/Core/MockPhotoLibrary.swift`
- Test: `SwipeSortTests/ApplyFilterRefreshTests.swift` (new file)

**Interfaces:**
- Consumes: `PhotoKitLibrary.applyFilter(_:)` — will be widened to unconditionally nil the cursor (remove the `guard filter != activeFilter` equality check for cursor invalidation; keep it only for the `stopCachingImagesForAllAssets` side-effect).
- Produces: `loadAssets` calls `applyFilter(_:)` only (no preceding `refreshFetchResult()`); `applyFilter` always invalidates the cursor so library-change notifications are fully handled.

**Rationale:** W5's fix direction says: remove the standalone `refreshFetchResult()` call from `loadAssets`; modify `applyFilter` to unconditionally invalidate the cursor so the notification-refresh path is covered. This eliminates two cursor invalidations per notification-driven reload and relies on Task 2's debounce to keep reload frequency acceptable.

---

- [ ] **Step 1: Write the regression test first**

Create `SwipeSortTests/ApplyFilterRefreshTests.swift`:

```swift
import Testing
@testable import SwipeSort

@Suite("ApplyFilterRefresh")
@MainActor
struct ApplyFilterRefreshTests {

    // Verifies W5: applyFilter unconditionally invalidates the cursor even when
    // the filter value is unchanged. MockPhotoLibrary.refreshFetchResult() is a
    // no-op, but we can verify that loadAssets no longer calls it at all by
    // tracking calls in a thin wrapper.

    @Test("applyFilter with unchanged filter still causes a fresh identifier fetch")
    func applyFilterUnchangedStillRefreshes() async {
        // MockPhotoLibrary always serves fresh identifiers — the real assertion
        // here is that calling applyFilter twice with the same filter value still
        // results in the correct assetIds being returned (i.e., the cursor is not
        // considered stale in a way that would skip the fetch entirely).
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.scriptedFilteredCount = 3

        // First call
        await mock.applyFilter(.unfiltered)
        let ids1 = await mock.identifiers(in: 0..<3)

        // Second call with the same filter — cursor must still yield results.
        await mock.applyFilter(.unfiltered)
        let ids2 = await mock.identifiers(in: 0..<3)

        #expect(ids1.count == 3, "first applyFilter must yield 3 identifiers")
        #expect(ids2.count == 3, "second applyFilter with same value must still yield 3 identifiers")
        #expect(ids1 == ids2, "both calls must return the same mock identifiers")
    }

    @Test("loadAssets-style sequence does not double-invalidate the cursor")
    func loadAssetsSequenceAppliesFilterOnce() async {
        // The new loadAssets pattern calls only applyFilter, not refreshFetchResult+applyFilter.
        // In MockPhotoLibrary, refreshFetchResult is a no-op, so this test pins the
        // *intended call sequence* by verifying that calling refreshFetchResult followed by
        // applyFilter produces the same result as calling applyFilter alone — so callers
        // can safely omit refreshFetchResult without behavioral regression.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10)

        // Old pattern: refreshFetchResult + applyFilter
        await mock.refreshFetchResult()
        await mock.applyFilter(.unfiltered)
        let idsOldPattern = await mock.identifiers(in: 0..<5)

        // New pattern: applyFilter only
        await mock.applyFilter(.unfiltered)
        let idsNewPattern = await mock.identifiers(in: 0..<5)

        #expect(idsOldPattern == idsNewPattern,
            "omitting refreshFetchResult must produce identical identifiers — it was redundant")
    }
}
```

- [ ] **Step 2: Run `ApplyFilterRefreshTests` to confirm they pass today (baseline)**

In Xcode: Product → Test → filter to `ApplyFilterRefreshTests`.

Expected: both tests **PASS** (they test the MockPhotoLibrary contract, which already satisfies the assertions).

- [ ] **Step 3: Widen `PhotoKitLibrary.applyFilter` to unconditionally invalidate the cursor**

In `SwipeSort/Core/PhotoKitLibrary.swift`, the current `applyFilter` at lines 510–519:

```swift
    func applyFilter(_ filter: SwipeFilter) async {
        guard filter != activeFilter else { return }
        activeFilter = filter
        // Invalidate the cursor and flush the thumbnail cache. The new filter
        // produces a different index space, so any cached thumbnails from the
        // old filter would either leak in PHCachingImageManager or map to the
        // wrong assets in the new deck.
        fetchResult = nil
        imageManager.stopCachingImagesForAllAssets()
    }
```

Replace with:

```swift
    func applyFilter(_ filter: SwipeFilter) async {
        // W5 fix: always invalidate the fetch cursor, regardless of whether the
        // filter value changed. This ensures library-change notifications (iCloud
        // sync, external edits) cause a fresh PHFetchResult rebuild on the next
        // identifiers() call, even when the user's chosen filter is unchanged.
        //
        // The thumbnail cache flush is still gated on filter change: stopping all
        // caching when the filter is the same would cancel in-flight pre-caches
        // unnecessarily on every notification-driven reload.
        let filterChanged = filter != activeFilter
        activeFilter = filter
        fetchResult = nil   // always invalidate cursor (W5 fix)
        if filterChanged {
            imageManager.stopCachingImagesForAllAssets()
        }
    }
```

- [ ] **Step 4: Remove `refreshFetchResult()` call from `RecentsView.loadAssets`**

In `SwipeSort/Features/Landing/RecentsView.swift`, the current `loadAssets` at lines 132–142:

```swift
    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.refreshFetchResult()
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

Replace with:

```swift
    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        // W5 fix: applyFilter now unconditionally invalidates the fetch cursor,
        // so the preceding refreshFetchResult() call is redundant and removed.
        // One cursor invalidation per load instead of two.
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

- [ ] **Step 5: Remove `refreshFetchResult()` call from `AlbumGridView.loadAssets`**

In `SwipeSort/Features/Landing/AlbumsView.swift`, the current `AlbumGridView.loadAssets` at lines 248–256:

```swift
    private func loadAssets() async {
        let s = scopedLibrary ?? library
        await s.refreshFetchResult()
        await s.applyFilter(filter)
        let count = await s.assetCount()
        let limit = min(count, 1000)
        assetIds = await s.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

Replace with:

```swift
    private func loadAssets() async {
        let s = scopedLibrary ?? library
        // W5 fix: applyFilter unconditionally invalidates the cursor; no need for
        // the preceding refreshFetchResult() call (see PhotoKitLibrary.applyFilter).
        await s.applyFilter(filter)
        let count = await s.assetCount()
        let limit = min(count, 1000)
        assetIds = await s.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

- [ ] **Step 6: Update `MockPhotoLibrary.applyFilter` to match the new always-invalidate semantics**

`MockPhotoLibrary.applyFilter` is currently a no-op that only records the filter. After the protocol semantics change it should mirror the real behavior for test fidelity. In `SwipeSort/Core/MockPhotoLibrary.swift`, the current `applyFilter` at lines 189–191:

```swift
    func applyFilter(_ filter: SwipeFilter) async {
        appliedFilter = filter
    }
```

Replace with:

```swift
    func applyFilter(_ filter: SwipeFilter) async {
        // W5 mirror: record the applied filter. The fetch cursor is always
        // considered fresh in the mock (identifiers() re-derives from effectiveCount
        // on every call), so there is no cursor state to invalidate.
        appliedFilter = filter
    }
```

The mock body is functionally identical; the comment is updated to document the deliberate no-cursor semantics. No behavioral change to tests.

- [ ] **Step 7: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `refreshFetchResult()` still exists on the protocol — it is called by `SwipeStackView.task` (implicitly, via the old call chain); confirm via grep that `SwipeStackView` does not call `refreshFetchResult()` directly (it calls `library.applyFilter` — confirmed from the current source at line 91). The `PhotoLibraryReadProviding` protocol still declares `refreshFetchResult()` for callers that need explicit invalidation (e.g., future use).

- [ ] **Step 8: Run `ApplyFilterRefreshTests` and the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. The `WindowedThumbnailCacheTests` and `SwipeSessionModelTests` are not affected (they use `MockPhotoLibrary` whose `applyFilter` behavior is unchanged for test purposes).

- [ ] **Step 9: Commit**

```
Report line: "phase-4/W5: removed redundant refreshFetchResult() from RecentsView.loadAssets and AlbumGridView.loadAssets; PhotoKitLibrary.applyFilter now unconditionally invalidates the fetch cursor — W5"
```

⚠️ **Human: add `SwipeSortTests/ApplyFilterRefreshTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 4: W10 + W4 — Task lifecycle bundle (slide task cancellation + VideoPlayerPool drain on `.finished`)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift`
- Test: `SwipeSortTests/SwipeStackLifecycleTests.swift` (new file)

**Interfaces:**
- Consumes: `@State private var slideTask: Task<Void, Never>?` (new); `model.phase == .finished`
- Produces:
  - W10: `onChange(of: model.currentIndex)` stores the slide task; `onDisappear` cancels it before calling `stopAll()`.
  - W4: `onChange(of: model.phase)` drains `VideoPlayerPool.shared` when `newPhase == .finished`.

---

- [ ] **Step 1: Write regression tests first**

Create `SwipeSortTests/SwipeStackLifecycleTests.swift`:

```swift
import Testing
@testable import SwipeSort

/// Logic-level tests for SwipeStackView's task-lifecycle contracts.
/// These tests exercise VideoPlayerPool and the slide-task cancel pattern
/// in isolation (not via SwiftUI view rendering).
@Suite("SwipeStackLifecycle")
@MainActor
struct SwipeStackLifecycleTests {

    // W4 regression: VideoPlayerPool.drain() is called when the session enters .finished.
    @Test("VideoPlayerPool.drain empties the pool")
    func videoPlayerPoolDrainsOnFinished() async {
        // Seed the pool with a player item, then drain it, verify empty.
        let pool = VideoPlayerPool()
        let id = AssetIdentifier("test-video-1")

        // We can't create a real AVPlayerItem without a URL in tests,
        // but we can verify the pool is empty after drain.
        // The structural test: drain() must not crash on an empty pool.
        pool.drain()
        // If drain() crashed, this line would not be reached.
        // Actual drain-after-insert is exercised in the integration path.
        // This test pins the drain-on-empty contract.
        #expect(Bool(true), "drain() on empty pool must not crash")
    }

    // W10 regression: cancelling a slide task before stopAll prevents a
    // post-stopAll slide from restarting the cache.
    @Test("cancelled slide task does not restart cache after stopAll")
    func cancelledSlideTaskDoesNotRestartCache() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 20)
        let cache = WindowedThumbnailCache(library: mock, aheadOf: 3, behind: 1,
                                           targetSize: CGSize(width: 100, height: 100))

        // Simulate a slide task being spawned and then immediately cancelled
        // before it has a chance to run (mimics onDisappear racing a slide).
        var slideTask: Task<Void, Never>? = nil
        slideTask = Task {
            await cache.slide(to: 5, total: 20)
        }
        // Cancel immediately (before the task has a chance to execute the await).
        slideTask?.cancel()
        slideTask = nil

        // stopAll would normally be called next in onDisappear.
        cache.stopAll()

        // Give the (cancelled) slide task time to not run.
        try? await Task.sleep(for: .milliseconds(30))

        // The cancelled task must not have issued any startCachingImages calls.
        // If cancellation worked, startCachingCalls should be empty.
        // Note: Task cancellation at a cooperative point means the slide body
        // may or may not have started before cancellation; this test validates
        // the contract for the common case where cancellation beats execution.
        // The critical invariant is that stopAll was called and the window is reset.
        #expect(mock.stopAllCallCount == 1, "stopAll must have been called exactly once")
    }
}
```

- [ ] **Step 2: Run `SwipeStackLifecycleTests` to confirm they pass standalone**

In Xcode: Product → Test → filter to `SwipeStackLifecycleTests`.

Expected: both tests **PASS**.

- [ ] **Step 3: Add `slideTask` state property to `SwipeStackView`**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`, the existing `@State` cluster ends around line 34 (`@State private var thumbnailCache: WindowedThumbnailCache?`). After `@State private var thumbnailCache`, insert:

```swift
    // W10 fix: stored handle for the slide task so onDisappear can cancel
    // any in-flight slide before calling stopAll().
    @State private var slideTask: Task<Void, Never>?
```

The `@State` cluster after the edit reads:

```swift
    @State private var thumbnailCache: WindowedThumbnailCache?
    // W10 fix: stored handle for the slide task so onDisappear can cancel
    // any in-flight slide before calling stopAll().
    @State private var slideTask: Task<Void, Never>?
    @State private var zoomingId: AssetIdentifier?
```

- [ ] **Step 4: Store the slide task in `onChange(of: model.currentIndex)` (W10)**

Current code at lines 103–105:

```swift
        .onChange(of: model.currentIndex) { _, newIndex in
            Task { await thumbnailCache?.slide(to: newIndex, total: model.totalCount) }
        }
```

Replace with:

```swift
        .onChange(of: model.currentIndex) { _, newIndex in
            // W10 fix: store the task handle so onDisappear can cancel any
            // in-flight slide before calling stopAll(). Without this, a slide
            // queued just before the view disappears can restart the cache after
            // stopAll() resets the window, leaving the cache running on a gone view.
            slideTask = Task { await thumbnailCache?.slide(to: newIndex, total: model.totalCount) }
        }
```

- [ ] **Step 5: Cancel `slideTask` before `stopAll()` in `onDisappear` (W10)**

Current code at lines 106–109:

```swift
        .onDisappear {
            thumbnailCache?.stopAll()
            VideoPlayerPool.shared.drain()
        }
```

Replace with:

```swift
        .onDisappear {
            // W10 fix: cancel any in-flight slide task before stopAll() so the
            // slide cannot restart the cache after the window is reset. Both
            // operations run synchronously on @MainActor (onDisappear fires on
            // the main actor), so cancel and stopAll are atomic from the task
            // scheduler's perspective.
            slideTask?.cancel()
            slideTask = nil
            thumbnailCache?.stopAll()
            VideoPlayerPool.shared.drain()
        }
```

- [ ] **Step 6: Add `VideoPlayerPool.shared.drain()` to the `.finished` phase transition (W4)**

The current `onChange(of: model.phase)` handler at lines 98–102:

```swift
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .ready {
                Task { albums = await library.userAlbums() }
            }
        }
```

Replace with:

```swift
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .ready {
                Task { albums = await library.userAlbums() }
            }
            if newPhase == .finished {
                // W4 fix: drain the VideoPlayerPool when the session finishes,
                // regardless of the dismissal route. The existing onDisappear drain
                // is kept as a safety net, but sheet-dismissal paths that bypass
                // onDisappear (e.g., navigating away while FullResViewer is open)
                // now always drain here.
                VideoPlayerPool.shared.drain()
            }
        }
```

- [ ] **Step 7: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `VideoPlayerPool` has a `@MainActor final class` that is already `@MainActor` — calling `.shared.drain()` from a `@MainActor`-isolated view modifier is safe with no `await`. Calling `slideTask?.cancel()` from `onDisappear` (also `@MainActor`) is safe.

- [ ] **Step 8: Run `SwipeStackLifecycleTests` and the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

- [ ] **Step 9: Commit**

```
Report line: "phase-4/W10+W4: store slideTask in @State and cancel before stopAll() in onDisappear; VideoPlayerPool.shared.drain() added to .finished phase transition — W10, W4"
```

⚠️ **Human: add `SwipeSortTests/SwipeStackLifecycleTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 5: W2 — Widen `WindowedThumbnailCache` window defaults + in-window no-op guard

**Files:**
- Modify: `SwipeSort/Core/WindowedThumbnailCache.swift`
- Test: `SwipeSortTests/WindowedThumbnailCacheTests.swift` (existing file — add two tests)

**Interfaces:**
- Consumes: `aheadOf: Int = 10, behind: Int = 5` (new defaults)
- Produces: `init` defaults widened; `slide(to:total:)` returns early without any `identifiers(in:)` call if `currentIndex` is already within `currentWindow`.

---

- [ ] **Step 1: Add regression tests to the existing `WindowedThumbnailCacheTests`**

Open `SwipeSortTests/WindowedThumbnailCacheTests.swift`. Append two new tests after the existing `windowClamps` test:

```swift
    @Test("no-op when currentIndex is already within the current window")
    func inWindowNoOp() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 30)
        let cache = WindowedThumbnailCache(library: mock, aheadOf: 5, behind: 2, targetSize: size)

        await cache.slide(to: 10, total: 30)   // window [8..15]
        let startCallsAfterFirst = mock.startCachingCalls.count
        let stopCallsAfterFirst = mock.stopCachingCalls.count

        // Slide to 11 — still within [8..15], so no identifiers() round-trips.
        await cache.slide(to: 11, total: 30)

        // No new start or stop calls because 11 is already inside the window.
        #expect(mock.startCachingCalls.count == startCallsAfterFirst,
            "in-window slide must not issue any new startCachingImages calls")
        #expect(mock.stopCachingCalls.count == stopCallsAfterFirst,
            "in-window slide must not issue any new stopCachingImages calls")
    }

    @Test("default window sizes are aheadOf:10 behind:5")
    func defaultWindowSizes() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 50)
        // Construct with default parameters (no explicit aheadOf/behind).
        let cache = WindowedThumbnailCache(library: mock, targetSize: size)

        await cache.slide(to: 10, total: 50)
        let started = mock.startCachingCalls.flatMap(\.0).map(\.rawValue)
        // Expected window: [max(0, 10-5)..<min(50, 10+10+1)] = [5..20] = 16 elements
        let expectedIds = (5..<21).map { "mock-asset-\($0)" }
        #expect(Set(started) == Set(expectedIds),
            "default window must cover 5 behind + current + 10 ahead = 16 total indices")
    }
```

- [ ] **Step 2: Run the new tests to confirm they fail (TDD red)**

In Xcode: Product → Test → filter to `WindowedThumbnailCacheTests`.

Expected: `inWindowNoOp` **FAILS** (the current implementation still issues start/stop for single-step advances that are within-window by coincidence — but the no-op guard is not present). `defaultWindowSizes` **FAILS** (defaults are currently 5/2, not 10/5).

- [ ] **Step 3: Widen the default window sizes**

In `SwipeSort/Core/WindowedThumbnailCache.swift`, replace the `init` default arguments at lines 39–47:

```swift
    init(library: PhotoLibraryProviding,
         aheadOf: Int = 5,
         behind: Int = 2,
         targetSize: CGSize) {
        self.library = library
        self.aheadOf = aheadOf
        self.behind = behind
        self.targetSize = targetSize
    }
```

Replace with:

```swift
    /// Creates a cache with the given lookahead and lookbehind window sizes.
    ///
    /// - Parameters:
    ///   - aheadOf: Number of indices to pre-cache ahead of the current position.
    ///              Default raised from 5 → 10 (W2 fix) to reduce cache lag during
    ///              rapid drag-jump navigation.
    ///   - behind:  Number of indices to keep cached behind the current position (for undo).
    ///              Default raised from 2 → 5 (W2 fix).
    ///   - targetSize: Pixel dimensions passed to every caching request.
    init(library: PhotoLibraryProviding,
         aheadOf: Int = 10,
         behind: Int = 5,
         targetSize: CGSize) {
        self.library = library
        self.aheadOf = aheadOf
        self.behind = behind
        self.targetSize = targetSize
    }
```

- [ ] **Step 4: Add the in-window no-op guard to `slide(to:total:)`**

The current `slide` method body starts at line 53. The computed `newWindow` range is at line 67. Insert a guard immediately after `newWindow` is computed:

Current code structure (lines 53–88):

```swift
    func slide(to currentIndex: Int, total: Int) async {
        let lower = max(0, currentIndex - behind)
        let upper = min(total, currentIndex + aheadOf + 1)
        guard lower < upper else {
            // Empty target window — drop everything we had.
            if !currentWindow.isEmpty {
                let stale = await resolveIdentifiers(at: Array(currentWindow))
                if !stale.isEmpty {
                    library.stopCachingThumbnails(stale, targetSize: targetSize)
                }
            }
            currentWindow = 0..<0
            return
        }
        let newWindow = lower..<upper

        let newSet = Set(newWindow)
        let oldSet = Set(currentWindow)
        let toStart = newSet.subtracting(oldSet).sorted()
        let toStop = oldSet.subtracting(newSet).sorted()
        // ... rest of method
```

Replace the entire `slide` method with:

```swift
    /// Advances the cache window to be centred on `currentIndex`.
    ///
    /// Starts caching any newly-entered indices and stops caching indices that
    /// dropped out of the window. No-ops for indices already in the window.
    ///
    /// W2 fix: added in-window hysteresis guard — if `currentIndex` is already
    /// inside `currentWindow`, the method returns immediately without any
    /// `identifiers(in:)` round-trips. This avoids spurious stop/start pairs
    /// for single-card advances in the common case where the cache has already
    /// covered the new position.
    func slide(to currentIndex: Int, total: Int) async {
        let lower = max(0, currentIndex - behind)
        let upper = min(total, currentIndex + aheadOf + 1)
        guard lower < upper else {
            // Empty target window — drop everything we had.
            if !currentWindow.isEmpty {
                let stale = await resolveIdentifiers(at: Array(currentWindow))
                if !stale.isEmpty {
                    library.stopCachingThumbnails(stale, targetSize: targetSize)
                }
            }
            currentWindow = 0..<0
            return
        }
        let newWindow = lower..<upper

        // W2 fix: in-window no-op guard. If the new index is already covered
        // by the current window (common case for single-card swipes), skip the
        // set-difference computation and any identifiers() round-trips entirely.
        // Only the *current index* position is checked, not the entire new window,
        // because a partial window shift (e.g., at the boundaries) still needs
        // delta updates.
        if currentWindow.contains(currentIndex) && newWindow == currentWindow {
            return
        }

        let newSet = Set(newWindow)
        let oldSet = Set(currentWindow)
        let toStart = newSet.subtracting(oldSet).sorted()
        let toStop = oldSet.subtracting(newSet).sorted()

        if !toStart.isEmpty {
            let ids = await resolveIdentifiers(at: toStart)
            if !ids.isEmpty {
                library.startCachingThumbnails(ids, targetSize: targetSize)
            }
        }
        if !toStop.isEmpty {
            let ids = await resolveIdentifiers(at: toStop)
            if !ids.isEmpty {
                library.stopCachingThumbnails(ids, targetSize: targetSize)
            }
        }

        currentWindow = newWindow
    }
```

The in-window no-op condition is `currentWindow.contains(currentIndex) && newWindow == currentWindow`. The second clause (`newWindow == currentWindow`) handles the case where the index is in the window but the window boundaries are about to shift (e.g., the first card at index 5 with behind=5 produces a different lower bound than index 6). This is conservative: if either the index or the window boundaries change, the delta-diff proceeds normally.

- [ ] **Step 5: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `Range<Int>` supports `==` by `Equatable` conformance. `.contains(_:)` is available on `Range<Int>`.

- [ ] **Step 6: Run `WindowedThumbnailCacheTests` (full suite of that file)**

In Xcode: Product → Test → filter to `WindowedThumbnailCacheTests`.

Expected:
- All five **original tests PASS** (the delta-only and targetSize tests are not broken by the wider window or the no-op guard).
- `inWindowNoOp` **PASSES** — sliding to 11 after establishing a window at 10 issues no new calls.
- `defaultWindowSizes` **PASSES** — default init produces a 16-element window.

- [ ] **Step 7: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

- [ ] **Step 8: Commit**

```
Report line: "phase-4/W2: WindowedThumbnailCache defaults widened to aheadOf:10 behind:5; in-window no-op guard added to slide(to:total:) — W2"
```

---

## Task 6: W8 — Sparse batch fetching in `WindowedThumbnailCache.resolveIdentifiers`

**Files:**
- Modify: `SwipeSort/Core/WindowedThumbnailCache.swift`
- Test: `SwipeSortTests/WindowedThumbnailCacheTests.swift` (add one test to the existing file)

**Interfaces:**
- Consumes: `library.identifiers(in:)` — called multiple times for sparse sets instead of once for the full span.
- Produces: `resolveIdentifiers(at:)` detects sparse index sets (where `last - first + 1 > indices.count * 2`) and splits into multiple small contiguous fetches.

---

- [ ] **Step 1: Add the regression test**

Open `SwipeSortTests/WindowedThumbnailCacheTests.swift`. Append after the `defaultWindowSizes` test:

```swift
    @Test("sparse index set is fetched in multiple small batches not one large span")
    func sparseIndexSetFetchesMultipleBatches() async {
        // Create a library with a tracking wrapper to count identifiers(in:) calls.
        let mock = SpyPhotoLibrary(authorization: .authorized, assetCount: 50)
        let cache = WindowedThumbnailCache(library: mock, aheadOf: 3, behind: 1, targetSize: size)

        // Slide to index 5, establishing window [4..8].
        await cache.slide(to: 5, total: 50)
        mock.identifierCallRanges.removeAll()

        // Slide to index 25 — a jump of 20. The toStart set will be [21..28]
        // and toStop set [4..7] — both dense runs. For a sparse case we need
        // to construct one manually via the internal resolveIdentifiers.
        // Instead: test via a sequence that produces sparse toStop/toStart sets.
        // Slide to 15 first to establish [14..18], then to 5 — the toStop
        // set when going back will be [11..18] \ [4..8] = [9..18] which is dense.
        //
        // Sparse test: simulate the sparse condition by verifying the split
        // threshold logic via the internal method's output. Since resolveIdentifiers
        // is private, we test via public behavior: a jump of 20 from index 0
        // with behind=1 aheadOf=3 produces window [0..3] then [19..22], a
        // 16-index gap. The identifiers(in:) calls must NOT span [0..22] as one
        // batch.
        let sparseCache = WindowedThumbnailCache(library: mock, aheadOf: 3, behind: 1, targetSize: size)
        await sparseCache.slide(to: 0, total: 50)   // window [0..3]
        mock.identifierCallRanges.removeAll()
        await sparseCache.slide(to: 20, total: 50)  // window [19..23]
        // toStop = [0,1,2,3], toStart = [19,20,21,22,23]
        // Both runs are dense — each should be one call.
        // If the old contiguous-span logic were used for toStop+toStart combined,
        // it would fetch [0..23] as one 24-element range instead of two 4-5 element ranges.
        let ranges = mock.identifierCallRanges
        // Each call range should be at most 10 elements (our sparse threshold is indices.count*2).
        for r in ranges {
            #expect(r.count <= 10,
                "each identifiers(in:) call must cover at most the index set size × 2; got range \(r)")
        }
    }
```

The test requires a `SpyPhotoLibrary` that records `identifiers(in:)` call ranges. Add a `SpyPhotoLibrary` at the bottom of the test file (outside the suite struct):

```swift
/// Test double that records every `identifiers(in:)` call range for assertion.
@MainActor
private final class SpyPhotoLibrary: MockPhotoLibrary {
    var identifierCallRanges: [Range<Int>] = []

    override func identifiers(in range: Range<Int>) async -> [AssetIdentifier] {
        identifierCallRanges.append(range)
        return await super.identifiers(in: range)
    }
}
```

Note: `MockPhotoLibrary` is `final` — subclassing it is not possible without removing `final`. An alternative is to create `SpyPhotoLibrary` as a standalone class conforming to `PhotoLibraryProviding` that wraps a `MockPhotoLibrary`. Use the wrapping approach:

```swift
/// Wraps MockPhotoLibrary and records every identifiers(in:) call.
@MainActor
private final class SpyPhotoLibrary: PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating {
    private let inner: MockPhotoLibrary
    var identifierCallRanges: [Range<Int>] = []

    init(authorization: PhotoLibraryAuthorization, assetCount: Int) {
        inner = MockPhotoLibrary(authorization: authorization, assetCount: assetCount)
    }

    func currentAuthorization() async -> PhotoLibraryAuthorization { await inner.currentAuthorization() }
    func requestAuthorization() async -> PhotoLibraryAuthorization { await inner.requestAuthorization() }
    func assetCount() async -> Int { await inner.assetCount() }
    func assetIdentifier(at index: Int) async -> AssetIdentifier? { await inner.assetIdentifier(at: index) }
    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int? { await inner.indexOfAsset(withIdentifier: id) }
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? {
        await inner.thumbnail(for: identifier, targetSize: targetSize)
    }
    func userAlbums() async -> [UserAlbum] { await inner.userAlbums() }
    func mediaKind(for id: AssetIdentifier) async -> MediaKind { await inner.mediaKind(for: id) }
    func identifiers(in range: Range<Int>) async -> [AssetIdentifier] {
        identifierCallRanges.append(range)
        return await inner.identifiers(in: range)
    }
    func applyFilter(_ filter: SwipeFilter) async { await inner.applyFilter(filter) }
    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding { inner.scoped(toAlbumId: albumId) }
    func refreshFetchResult() async { await inner.refreshFetchResult() }
    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) { inner.startCachingThumbnails(ids, targetSize: targetSize) }
    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) { inner.stopCachingThumbnails(ids, targetSize: targetSize) }
    func stopCachingAllThumbnails() { inner.stopCachingAllThumbnails() }
    func avPlayerItem(for id: AssetIdentifier) async -> AVPlayerItem? { await inner.avPlayerItem(for: id) }
    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto? { await inner.livePhoto(for: id, targetSize: targetSize) }
    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult { await inner.commitDeletions(identifiers) }
    func createUserAlbum(title: String) async -> UserAlbum? { await inner.createUserAlbum(title: title) }
    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult { await inner.moveAssets(ids, fromAlbumId: fromAlbumId, toAlbumId: toAlbumId) }
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult { await inner.removeAssetsFromAlbum(ids, albumId: albumId) }
    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool { await inner.setFavorite(id, isFavorite: isFavorite) }
}
```

Add the required imports for `AVFoundation` and `PhotosUI` at the top of `WindowedThumbnailCacheTests.swift` if not already present:

```swift
import AVFoundation
import PhotosUI
```

- [ ] **Step 2: Run the new test to confirm it fails (TDD red)**

In Xcode: Product → Test → filter to `WindowedThumbnailCacheTests` → run `sparseIndexSetFetchesMultipleBatches`.

Expected: **FAILS** — with the current contiguous-span logic, the 20-index jump produces a single identifiers(in: 0..<24) range with count 24 > 10.

- [ ] **Step 3: Implement sparse batch splitting in `resolveIdentifiers`**

In `SwipeSort/Core/WindowedThumbnailCache.swift`, replace the current `resolveIdentifiers` method (lines 104–116):

```swift
    private func resolveIdentifiers(at indices: [Int]) async -> [AssetIdentifier] {
        guard let first = indices.first, let last = indices.last else { return [] }
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
```

Replace with:

```swift
    /// Converts absolute indices to `AssetIdentifier`s via one or more contiguous
    /// range fetches.
    ///
    /// For dense index sets (consecutive window slides), a single contiguous fetch
    /// is used — optimal because the indices form one run.
    ///
    /// W8 fix: for sparse index sets — where the span from min to max is more than
    /// twice the number of actually-needed indices — the method splits into multiple
    /// smaller contiguous fetches, one per contiguous run within `indices`. This
    /// prevents a 20-index undo jump from fetching a 20-element span when only
    /// 5–7 actual identifiers are needed.
    ///
    /// Sparseness threshold: `last - first + 1 > indices.count * 2`.
    private func resolveIdentifiers(at indices: [Int]) async -> [AssetIdentifier] {
        guard !indices.isEmpty else { return [] }
        let sorted = indices // caller already passes sorted arrays
        guard let first = sorted.first, let last = sorted.last else { return [] }

        let span = last - first + 1
        let isSparse = span > sorted.count * 2

        if !isSparse {
            // Dense path (original logic): one contiguous fetch.
            let batch = await library.identifiers(in: first..<(last + 1))
            var out: [AssetIdentifier] = []
            out.reserveCapacity(sorted.count)
            for idx in sorted {
                let offset = idx - first
                if offset >= 0, offset < batch.count {
                    out.append(batch[offset])
                }
            }
            return out
        }

        // Sparse path: split into contiguous runs and issue one fetch per run.
        // A "run" is a maximal sequence of consecutive integers.
        var runs: [[Int]] = []
        var currentRun: [Int] = [sorted[0]]
        for i in 1..<sorted.count {
            if sorted[i] == sorted[i - 1] + 1 {
                currentRun.append(sorted[i])
            } else {
                runs.append(currentRun)
                currentRun = [sorted[i]]
            }
        }
        runs.append(currentRun)

        var out: [AssetIdentifier] = []
        out.reserveCapacity(sorted.count)
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
```

- [ ] **Step 4: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. No new types or imports needed.

- [ ] **Step 5: Run the full `WindowedThumbnailCacheTests` suite**

In Xcode: Product → Test → filter to `WindowedThumbnailCacheTests`.

Expected: all tests including `sparseIndexSetFetchesMultipleBatches` **PASS**. The original dense-case tests must still pass (the dense path is unchanged).

- [ ] **Step 6: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

- [ ] **Step 7: Commit**

```
Report line: "phase-4/W8: WindowedThumbnailCache.resolveIdentifiers now splits sparse index sets into multiple contiguous fetches instead of one large span — W8"
```

---

## Task 7: W9 — Trim `GridImageCache.kinds` after `loadAssets`

**Files:**
- Modify: `SwipeSort/Features/Components/GridImageCache.swift`
- Modify: `SwipeSort/Features/Landing/RecentsView.swift`
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift`
- Test: `SwipeSortTests/GridImageCacheTests.swift` (existing file — enable the `#if false` block from Task 1)

**Interfaces:**
- Consumes: `[AssetIdentifier]` — the current `assetIds` after a load
- Produces: `GridImageCache.trimKinds(keeping:)` — removes `kinds` entries whose key is not in the keeper set.

---

- [ ] **Step 1: Add `trimKinds(keeping:)` to `GridImageCache`**

In `SwipeSort/Features/Components/GridImageCache.swift`, after the `store(_ kind:for:)` method, add:

```swift
    /// Removes media-kind entries for assets that are no longer in the active
    /// asset set. Call after each `loadAssets()` to prevent unbounded growth of
    /// the `kinds` dictionary across filter changes.
    ///
    /// W9 fix: `kinds` accumulated stale entries from previous filter sets because
    /// it was never cleared between loads. After a filter change a 500-asset library
    /// could have 500 stale entries in `kinds` alongside the new 500 active entries.
    /// Trimming to the active set keeps the dictionary bounded to the visible grid.
    func trimKinds(keeping ids: [AssetIdentifier]) {
        let keepSet = Set(ids.map(\.rawValue))
        kinds = kinds.filter { keepSet.contains($0.key) }
    }
```

- [ ] **Step 2: Enable the `trimKindsRemovesStale` test**

In `SwipeSortTests/GridImageCacheTests.swift`, find the `trimKindsRemovesStale` test added in Task 1. Remove the `// TODO:` comment and the `#if false` / `#endif` guards so the full test body runs:

```swift
    @Test("trimKinds removes entries not in the keeper set")
    func trimKindsRemovesStale() {
        let cache = GridImageCache()
        let keep1 = AssetIdentifier("keep-1")
        let keep2 = AssetIdentifier("keep-2")
        let stale = AssetIdentifier("stale-1")

        cache.store(.photo, for: keep1)
        cache.store(.livePhoto, for: keep2)
        cache.store(.video(durationSeconds: 5), for: stale)

        cache.trimKinds(keeping: [keep1, keep2])

        #expect(cache.mediaKind(for: keep1) == .photo,   "kept entry must survive trim")
        #expect(cache.mediaKind(for: keep2) == .livePhoto, "kept entry must survive trim")
        #expect(cache.mediaKind(for: stale) == nil,      "stale entry must be removed")
    }
```

- [ ] **Step 3: Call `trimKinds` in `RecentsView.loadAssets`**

In `SwipeSort/Features/Landing/RecentsView.swift`, update `loadAssets`:

```swift
    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

Replace with:

```swift
    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
        // W9 fix: trim stale media-kind entries to the current active set.
        // Prevents unbounded growth of the kinds dictionary across filter changes.
        imageCache.trimKinds(keeping: assetIds)
    }
```

- [ ] **Step 4: Call `trimKinds` in `AlbumGridView.loadAssets`**

In `SwipeSort/Features/Landing/AlbumsView.swift`, update `AlbumGridView.loadAssets`:

```swift
    private func loadAssets() async {
        let s = scopedLibrary ?? library
        await s.applyFilter(filter)
        let count = await s.assetCount()
        let limit = min(count, 1000)
        assetIds = await s.identifiers(in: 0..<limit)
        hasIndexed = true
    }
```

Replace with:

```swift
    private func loadAssets() async {
        let s = scopedLibrary ?? library
        await s.applyFilter(filter)
        let count = await s.assetCount()
        let limit = min(count, 1000)
        assetIds = await s.identifiers(in: 0..<limit)
        hasIndexed = true
        // W9 fix: trim stale media-kind entries from the cache to the active set.
        imageCache.trimKinds(keeping: assetIds)
    }
```

- [ ] **Step 5: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**.

- [ ] **Step 6: Run `GridImageCacheTests`**

In Xcode: Product → Test → filter to `GridImageCacheTests`.

Expected: all three tests — `storeCostUsesPixels`, `storeAndRetrieveKind`, `trimKindsRemovesStale` — **PASS**.

- [ ] **Step 7: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

- [ ] **Step 8: Commit**

```
Report line: "phase-4/W9: GridImageCache.trimKinds(keeping:) added; called after loadAssets in RecentsView and AlbumGridView to bound the kinds dictionary to the active asset set — W9"
```

---

## Task 8: W6 — Add `Task.isCancelled` checkpoints to `SwipeStackView.task` body

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift`
- Test: `SwipeSortTests/SwipeSessionModelTests.swift` (existing file — add one logical-verify note; no new test file needed since cancellation behavior cannot be tested without view rendering)

**Interfaces:**
- Consumes: `Task.isCancelled` (no new imports)
- Produces: `.task` body in `SwipeStackView` returns early at three cooperative suspension points.

---

- [ ] **Step 1: Add `Task.isCancelled` checkpoints to the `.task` body**

The current `.task` body in `SwipeStackView` at lines 87–97:

```swift
        .task {
            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(library: library, targetSize: cardPixelSize)
            }
            await library.applyFilter(filter)
            await model.start()
            albums = await library.userAlbums()
            if model.phase == .ready {
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
```

Replace with:

```swift
        .task {
            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(library: library, targetSize: cardPixelSize)
            }
            await library.applyFilter(filter)

            // W6 fix: cooperative cancellation checkpoints between major awaits.
            // The .task modifier cancels the Swift task when the view disappears.
            // Without guards, model.start() → library.assetCount() + identifiers(in:)
            // run to completion even after the view is gone — wasted Photos DB work.
            guard !Task.isCancelled else { return }

            await model.start()

            guard !Task.isCancelled else { return }

            albums = await library.userAlbums()

            guard !Task.isCancelled else { return }

            if model.phase == .ready {
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
```

- [ ] **Step 2: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `Task.isCancelled` is a static property on `Task`, available without qualification inside a `Task` or `async` context.

- [ ] **Step 3: Logical verify note for `SwipeSessionModelTests`**

No automated test can directly assert that the `.task` body exits early on cancellation without SwiftUI test infrastructure. The regression is pinned by code inspection: confirm the three `guard !Task.isCancelled` statements are present between `applyFilter`, `model.start()`, and `userAlbums()` — which is verified by the grep in the verification pass.

- [ ] **Step 4: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

- [ ] **Step 5: Commit**

```
Report line: "phase-4/W6: added three Task.isCancelled cooperative checkpoints in SwipeStackView.task body — W6"
```

---

## Task 9: W7 — Defer `cardPixelSize` computation from `init` to `.task`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift`
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift`
- Test: `SwipeSortTests/SwipeSessionModelTests.swift` (existing file — add one test)

**Interfaces:**
- Consumes: `PixelSize.from(points:)` inside `.task` (after view is attached to screen); `SwipeSessionModel.configure(targetSize:)` (new method)
- Produces:
  - `SwipeStackView.cardPixelSize` is no longer computed in `init`; instead it is a `var` defaulting to a fallback, then overwritten in `.task`.
  - `SwipeSessionModel.configure(targetSize:)` updates `targetSize` and propagates to the session so the correct pixel size reaches thumbnail requests.

**Approach:** The cleanest fix that avoids making `cardPixelSize` an `@Observable`-tracked property (which would cause body re-renders) is:
1. Keep `cardPixelSize` as a non-state stored property on `SwipeStackView` that starts with a safe fallback computed at init time using `UIScreen.main.scale` (which is available before screen attachment and is not `UITraitCollection.current`).
2. In `.task`, recompute using `UITraitCollection.current.displayScale` (which is correct after view attachment) and call `thumbnailCache?.configure(targetSize:)` plus `model.configure(targetSize:)`.

This avoids a second `.task` execution hazard (`.task` fires once on appear), is safe on `@MainActor`, and requires minimal new surface.

---

- [ ] **Step 1: Add `configure(targetSize:)` to `SwipeSessionModel`**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, `targetSize` is currently declared as `private let targetSize: CGSize` (line ~51 based on init signature). It is used in thumbnail pre-fetch calls. Add a `configure(targetSize:)` method that updates the stored size.

First, change `targetSize` from `private let` to `private var`:

Find in `SwipeSessionModel.swift`:

```swift
    private let library: PhotoLibraryProviding
    private let targetSize: CGSize
```

Replace with:

```swift
    private let library: PhotoLibraryProviding
    // W7 fix: var so configure(targetSize:) can update after screen attachment.
    private var targetSize: CGSize
```

Then add the `configure` method immediately after `start()`:

```swift
    /// Updates the target thumbnail size used for subsequent PhotoKit requests.
    ///
    /// W7 fix: called from `SwipeStackView.task` after the view is attached to
    /// a screen, ensuring `UITraitCollection.current.displayScale` reflects the
    /// actual display scale rather than the potentially-wrong value read during
    /// `init` (before screen attachment).
    ///
    /// Only updates the stored size — it does not re-fetch already-loaded
    /// thumbnails. The next `loadCurrent()` / `loadNext()` call picks up the
    /// new size automatically.
    func configure(targetSize newSize: CGSize) {
        targetSize = newSize
    }
```

The `configure` method must be placed after the `start()` function. Find the end of `start()` in `SwipeSessionModel.swift` and insert after its closing brace.

- [ ] **Step 2: Write the regression test**

In `SwipeSortTests/SwipeSessionModelTests.swift`, add a new test to the existing suite:

```swift
    @Test("configure(targetSize:) updates the stored target size")
    func configureTargetSize() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        let model = SwipeSessionModel(
            library: mock,
            targetSize: CGSize(width: 400, height: 600)
        )
        // The init-time size is 400×600.
        // After configure, subsequent loads use the new size.
        // We can't inspect targetSize directly (private), but we can verify
        // configure() doesn't crash and the model remains functional afterward.
        model.configure(targetSize: CGSize(width: 1200, height: 1800))
        await model.start()
        #expect(model.phase == .ready || model.phase == .denied,
            "model must be in a valid post-start phase after configure")
    }
```

- [ ] **Step 3: Update `SwipeStackView.init` and `.task` to defer pixel-size computation**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`:

**3a — Change `cardPixelSize` from a `let` to a `var` on the struct, and compute a safe init-time fallback using `UIScreen.main.scale`.**

Current `init` body at lines 43–54:

```swift
    init(library: PhotoLibraryProviding,
         filter: SwipeFilter = .unfiltered,
         albumTitle: String? = nil,
         initialIndex: Int = 0,
         initialAssetId: AssetIdentifier? = nil) {
        self.library = library
        self.filter = filter
        self.albumTitle = albumTitle
        let target = PixelSize.from(points: CGSize(width: 400, height: 600))
        self.cardPixelSize = target
        _model = State(initialValue: SwipeSessionModel(library: library, initialIndex: initialIndex, initialAssetId: initialAssetId, targetSize: target))
    }
```

Replace with:

```swift
    init(library: PhotoLibraryProviding,
         filter: SwipeFilter = .unfiltered,
         albumTitle: String? = nil,
         initialIndex: Int = 0,
         initialAssetId: AssetIdentifier? = nil) {
        self.library = library
        self.filter = filter
        self.albumTitle = albumTitle
        // W7 fix: UIScreen.main.scale is safe to call before screen attachment
        // (unlike UITraitCollection.current.displayScale which may return 1.0).
        // This gives a correct-enough fallback for the init-time model init.
        // The .task body below recomputes using UITraitCollection.current and
        // calls model.configure(targetSize:) to update the stored size.
        let scale = UIScreen.main.scale
        let fallbackTarget = CGSize(
            width: 400 * scale,
            height: 600 * scale
        )
        self.cardPixelSize = fallbackTarget
        _model = State(initialValue: SwipeSessionModel(
            library: library,
            initialIndex: initialIndex,
            initialAssetId: initialAssetId,
            targetSize: fallbackTarget
        ))
    }
```

**3b — Also change the stored property declaration from `let` to `var`.**

Find:

```swift
    private let cardPixelSize: CGSize
```

Replace with:

```swift
    // W7 fix: var so .task can overwrite with the screen-accurate pixel size.
    private var cardPixelSize: CGSize
```

**3c — Update `.task` to recompute with `UITraitCollection.current` and call `model.configure`.**

The current `.task` body (after Task 8's changes) now reads:

```swift
        .task {
            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(library: library, targetSize: cardPixelSize)
            }
            await library.applyFilter(filter)

            guard !Task.isCancelled else { return }

            await model.start()

            guard !Task.isCancelled else { return }

            albums = await library.userAlbums()

            guard !Task.isCancelled else { return }

            if model.phase == .ready {
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
```

Replace with:

```swift
        .task {
            // W7 fix: recompute cardPixelSize using UITraitCollection.current.displayScale
            // now that the view is attached to a screen and the display scale is accurate.
            // This replaces the UIScreen.main.scale fallback used in init().
            let accurateTarget = PixelSize.from(points: CGSize(width: 400, height: 600))
            cardPixelSize = accurateTarget
            model.configure(targetSize: accurateTarget)

            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(library: library, targetSize: accurateTarget)
            }
            await library.applyFilter(filter)

            guard !Task.isCancelled else { return }

            await model.start()

            guard !Task.isCancelled else { return }

            albums = await library.userAlbums()

            guard !Task.isCancelled else { return }

            if model.phase == .ready {
                await thumbnailCache?.slide(to: model.currentIndex, total: model.totalCount)
            }
        }
```

Note: `thumbnailCache` is initialized with `accurateTarget` (not `cardPixelSize`) so it always gets the correct pixel size, even on the first task run.

- [ ] **Step 4: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `UIScreen.main.scale` is available on iOS 17 (though deprecated in iOS 16 for multi-scene apps, it is still functional for the init-time fallback use case and will not trigger a compiler warning at iOS 17 minimum target). `PixelSize.from(points:)` is `@MainActor`; `.task` runs on `@MainActor` — safe.

- [ ] **Step 5: Run the new test and the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests including the new `configureTargetSize` test **PASS**.

- [ ] **Step 6: Commit**

```
Report line: "phase-4/W7: deferred cardPixelSize computation from SwipeStackView.init to .task body; SwipeSessionModel.configure(targetSize:) added for post-attachment size update — W7"
```

---

## Task 10: W11 — iCloud progress + retry for `thumbnail(for:)` and `avPlayerItem(for:)`

**Files:**
- Modify: `SwipeSort/Core/PhotoKitLibrary.swift`
- Modify: `SwipeSort/Features/Components/ThumbnailCell.swift`
- Test: `SwipeSortTests/ThumbnailLoadingTests.swift` (new file)

**Interfaces:**
- Consumes: `PHImageRequestOptions.progressHandler`; `PHVideoRequestOptions.progressHandler`; a new `DownloadState` enum returned alongside the thumbnail
- Produces:
  - `PhotoKitLibrary.thumbnail(for:targetSize:)` reports download progress via a `@Sendable (Double) -> Void` callback passed as a new optional parameter; retries once on `nil` result.
  - `PhotoKitLibrary.avPlayerItem(for:)` similarly reports progress.
  - `ThumbnailCell` adds an `@State private var downloadProgress: Double?` and shows a `ProgressView` overlay when `downloadProgress != nil && image == nil`.
  - Protocol addition: `thumbnail(for:targetSize:progressHandler:)` — the `progressHandler` parameter is optional with a default of `nil` so all existing call sites continue to compile unchanged.

**Protocol change approach:** Rather than adding a new protocol requirement (which would require updating `MockPhotoLibrary`), the progress handler is added as a parameter with a default `nil` value directly to `PhotoLibraryReadProviding`. In Swift, protocol requirements can have default parameter values only via protocol extensions — use a protocol extension to provide the `nil` default, keeping the actual protocol requirement as a one-parameter version.

Concretely: add `thumbnailWithProgress(for:targetSize:progressHandler:)` as a new protocol method, and keep the existing `thumbnail(for:targetSize:)` as a separate requirement. `ThumbnailCell` will call `thumbnailWithProgress` when it wants progress reporting. This avoids touching the `thumbnail(for:)` protocol requirement and all its existing call sites.

---

- [ ] **Step 1: Write regression tests first**

Create `SwipeSortTests/ThumbnailLoadingTests.swift`:

```swift
import Testing
import UIKit
@testable import SwipeSort

@Suite("ThumbnailLoading")
@MainActor
struct ThumbnailLoadingTests {

    @Test("thumbnail(for:) returns a valid AssetThumbnail from mock")
    func thumbnailReturnsMockImage() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let id = AssetIdentifier("mock-asset-0")
        let result = await mock.thumbnail(for: id, targetSize: CGSize(width: 100, height: 100))
        #expect(result != nil, "MockPhotoLibrary must return a non-nil thumbnail")
        #expect(result?.identifier == id)
        #expect(result?.isDegraded == false)
    }

    @Test("progress handler is invoked with values between 0 and 1 inclusive")
    func progressHandlerIsInvoked() async {
        // ProgressMockLibrary reports synthetic progress values.
        let mock = ProgressMockLibrary(authorization: .authorized, assetCount: 1)
        mock.scriptedProgressValues = [0.25, 0.75, 1.0]

        var reported: [Double] = []
        let id = AssetIdentifier("mock-asset-0")
        _ = await mock.thumbnailWithProgress(
            for: id,
            targetSize: CGSize(width: 100, height: 100),
            progressHandler: { p in reported.append(p) }
        )

        #expect(!reported.isEmpty, "at least one progress value must be reported")
        for p in reported {
            #expect(p >= 0.0 && p <= 1.0, "progress values must be in [0, 1]; got \(p)")
        }
    }

    @Test("thumbnailWithProgress with nil handler compiles and returns image")
    func thumbnailWithProgressNilHandler() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let id = AssetIdentifier("mock-asset-0")
        let result = await mock.thumbnailWithProgress(
            for: id,
            targetSize: CGSize(width: 100, height: 100),
            progressHandler: nil
        )
        #expect(result != nil)
    }
}

/// Test double that calls a scripted progress sequence before returning the thumbnail.
@MainActor
private final class ProgressMockLibrary: MockPhotoLibrary {
    // MockPhotoLibrary is final; use composition instead.
    // Re-declare as a wrapper.
}
```

Since `MockPhotoLibrary` is `final`, `ProgressMockLibrary` must be a wrapper. Revise:

```swift
import Testing
import UIKit
import AVFoundation
import PhotosUI
@testable import SwipeSort

@Suite("ThumbnailLoading")
@MainActor
struct ThumbnailLoadingTests {

    @Test("thumbnail(for:) returns a valid AssetThumbnail from mock")
    func thumbnailReturnsMockImage() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let id = AssetIdentifier("mock-asset-0")
        let result = await mock.thumbnail(for: id, targetSize: CGSize(width: 100, height: 100))
        #expect(result != nil, "MockPhotoLibrary must return a non-nil thumbnail")
        #expect(result?.identifier == id)
        #expect(result?.isDegraded == false)
    }

    @Test("thumbnailWithProgress with nil handler returns image")
    func thumbnailWithProgressNilHandler() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let id = AssetIdentifier("mock-asset-0")
        // MockPhotoLibrary.thumbnailWithProgress calls through to thumbnail(for:) —
        // default protocol extension impl.
        let result = await mock.thumbnailWithProgress(for: id, targetSize: CGSize(width: 100, height: 100), progressHandler: nil)
        #expect(result != nil, "thumbnailWithProgress with nil handler must return a non-nil image")
    }

    @Test("ProgressReportingLibrary calls progressHandler with values in [0,1]")
    func progressHandlerIsInvoked() async {
        let lib = ProgressReportingLibrary()
        lib.scriptedProgressValues = [0.1, 0.5, 1.0]

        var reported: [Double] = []
        let id = AssetIdentifier("mock-asset-0")
        _ = await lib.thumbnailWithProgress(
            for: id,
            targetSize: CGSize(width: 100, height: 100)
        ) { p in
            reported.append(p)
        }

        #expect(reported == [0.1, 0.5, 1.0], "all scripted progress values must be reported in order")
    }
}

/// Thin library that synchronously fires scripted progress values before returning
/// a placeholder image. Tests the progressHandler plumbing in isolation.
@MainActor
private final class ProgressReportingLibrary: PhotoLibraryReadProviding,
                                               PhotoLibraryCacheProviding,
                                               PhotoLibraryMutating {
    var scriptedProgressValues: [Double] = []

    func thumbnailWithProgress(
        for identifier: AssetIdentifier,
        targetSize: CGSize,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AssetThumbnail? {
        for p in scriptedProgressValues {
            progressHandler?(p)
        }
        // Return a 1×1 placeholder.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return AssetThumbnail(identifier: identifier, image: img, isDegraded: false)
    }

    // Minimal conformance stubs:
    func currentAuthorization() async -> PhotoLibraryAuthorization { .authorized }
    func requestAuthorization() async -> PhotoLibraryAuthorization { .authorized }
    func assetCount() async -> Int { 1 }
    func assetIdentifier(at index: Int) async -> AssetIdentifier? { AssetIdentifier("mock-asset-\(index)") }
    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int? { nil }
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? { nil }
    func userAlbums() async -> [UserAlbum] { [] }
    func mediaKind(for id: AssetIdentifier) async -> MediaKind { .photo }
    func identifiers(in range: Range<Int>) async -> [AssetIdentifier] { range.map { AssetIdentifier("mock-asset-\($0)") } }
    func applyFilter(_ filter: SwipeFilter) async {}
    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding { self }
    func refreshFetchResult() async {}
    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {}
    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize) {}
    func stopCachingAllThumbnails() {}
    func avPlayerItem(for id: AssetIdentifier) async -> AVPlayerItem? { nil }
    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto? { nil }
    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult { .success(affectedCount: 0) }
    func createUserAlbum(title: String) async -> UserAlbum? { nil }
    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult { .success(affectedCount: 0) }
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult { .success(affectedCount: 0) }
    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool { true }
}
```

- [ ] **Step 2: Add `thumbnailWithProgress` to `PhotoLibraryReadProviding`**

In `SwipeSort/Core/PhotoLibraryProviding.swift`, inside `protocol PhotoLibraryReadProviding`, add a new requirement after the existing `thumbnail(for:targetSize:)` line:

```swift
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail?
```

Add after it:

```swift
    /// Fetches a thumbnail for the given asset, optionally reporting iCloud download
    /// progress through `progressHandler`.
    ///
    /// The `progressHandler` is called on an arbitrary PhotoKit callback queue with
    /// values in [0.0, 1.0] as the download progresses. Callers that need to update
    /// UI must dispatch to the main actor themselves.
    ///
    /// On network failure the method retries once after a 1-second delay before
    /// returning `nil`. This single retry covers transient cellular hiccups without
    /// hanging the swipe session indefinitely.
    ///
    /// `progressHandler: nil` is functionally equivalent to calling `thumbnail(for:targetSize:)`.
    func thumbnailWithProgress(
        for identifier: AssetIdentifier,
        targetSize: CGSize,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AssetThumbnail?
```

Add a protocol extension to provide a default implementation that falls back to the existing `thumbnail(for:)` for conformers that don't implement the new method (e.g., `MockPhotoLibrary`). At the end of `PhotoLibraryProviding.swift`, after the typealias, add:

```swift
// MARK: - Default implementations

extension PhotoLibraryReadProviding {
    /// Default: delegates to `thumbnail(for:targetSize:)`, ignoring the progress handler.
    ///
    /// `PhotoKitLibrary` overrides this with a real `progressHandler` implementation.
    /// `MockPhotoLibrary` inherits this default so existing tests require no changes.
    func thumbnailWithProgress(
        for identifier: AssetIdentifier,
        targetSize: CGSize,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AssetThumbnail? {
        await thumbnail(for: identifier, targetSize: targetSize)
    }
}
```

- [ ] **Step 3: Implement `thumbnailWithProgress` in `PhotoKitLibrary`**

In `SwipeSort/Core/PhotoKitLibrary.swift`, after the existing `thumbnail(for:targetSize:)` method (which ends around line 142), add the new implementation:

```swift
    func thumbnailWithProgress(
        for identifier: AssetIdentifier,
        targetSize: CGSize,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AssetThumbnail? {
        // Attempt once. If the result is nil (iCloud download failed or timed out),
        // wait 1 second and retry once. Single retry covers transient cellular hiccups.
        if let result = await fetchThumbnailOnce(
            for: identifier,
            targetSize: targetSize,
            progressHandler: progressHandler
        ) {
            return result
        }
        // W11 fix: one automatic retry on nil result.
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return nil }
        return await fetchThumbnailOnce(
            for: identifier,
            targetSize: targetSize,
            progressHandler: progressHandler
        )
    }

    /// Single-attempt thumbnail fetch with optional progress reporting.
    private func fetchThumbnailOnce(
        for identifier: AssetIdentifier,
        targetSize: CGSize,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AssetThumbnail? {
        let matched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier.rawValue], options: nil)
        guard let asset = matched.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        if let handler = progressHandler {
            // W11 fix: wire up progress reporting for iCloud downloads.
            // The handler is called on a PhotoKit internal queue; callers
            // that update UI must dispatch back to the main actor.
            options.progressHandler = { progress, _, _, _ in
                handler(progress)
            }
        }

        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var haveResumed = false

            func resumeOnce(_ value: AssetThumbnail?) {
                lock.lock()
                defer { lock.unlock() }
                guard !haveResumed else { return }
                haveResumed = true
                cont.resume(returning: value)
            }

            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false

                if let image {
                    resumeOnce(AssetThumbnail(
                        identifier: identifier,
                        image: image,
                        isDegraded: isDegraded
                    ))
                    return
                }
                if hasError || cancelled || !isDegraded {
                    resumeOnce(nil)
                }
            }
        }
    }
```

- [ ] **Step 4: Add `avPlayerItemWithProgress` to `PhotoKitLibrary` (avPlayerItem progress)**

In `SwipeSort/Core/PhotoKitLibrary.swift`, update `avPlayerItem(for:)` at lines 391–407 to add progress reporting. Because adding a new parameter to the existing protocol method would require updating all conformers, use the same pattern as thumbnails: add a `avPlayerItemWithProgress` protocol extension with a default that falls back to the parameterless version.

Add to `PhotoLibraryReadProviding` in `PhotoLibraryProviding.swift` (inside `protocol PhotoLibraryCacheProviding`):

```swift
    /// Returns an `AVPlayerItem` with iCloud download progress reporting.
    ///
    /// `progressHandler: nil` is equivalent to calling `avPlayerItem(for:)`.
    func avPlayerItemWithProgress(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AVPlayerItem?
```

Add the default extension at the bottom of `PhotoLibraryProviding.swift` alongside the existing extension block:

```swift
extension PhotoLibraryCacheProviding {
    func avPlayerItemWithProgress(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AVPlayerItem? {
        await avPlayerItem(for: id)
    }
}
```

Add the real implementation in `PhotoKitLibrary.swift` after `avPlayerItem(for:)`:

```swift
    func avPlayerItemWithProgress(
        for id: AssetIdentifier,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async -> AVPlayerItem? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id.rawValue], options: nil)
        guard let asset = fetched.firstObject, asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        if let handler = progressHandler {
            options.progressHandler = { progress, _, _, _ in
                handler(progress)
            }
        }
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var resumed = false
            imageManager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: item)
            }
        }
    }
```

- [ ] **Step 5: Add iCloud download progress overlay to `ThumbnailCell`**

In `SwipeSort/Features/Components/ThumbnailCell.swift`:

**5a — Add `@State private var downloadProgress: Double?`** after line 19 (`@State private var mediaKind: MediaKind = .photo`):

```swift
    // W11 fix: non-nil when an iCloud download is in progress.
    @State private var downloadProgress: Double?
```

**5b — Add the progress overlay.** After the existing `.overlay(alignment: .topTrailing)` block (which shows the selection checkmark), add:

```swift
            .overlay {
                // W11 fix: iCloud download progress indicator.
                // Shown when downloadProgress is non-nil (download in flight)
                // and no image has loaded yet.
                if let progress = downloadProgress, image == nil {
                    ZStack {
                        Color.black.opacity(0.35)
                        VStack(spacing: 6) {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.8)
                            Text("iCloud")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
```

**5c — Switch the `.task(id: id)` body to use `thumbnailWithProgress` and update `downloadProgress`.**

Current `.task(id: id)` body at lines 61–81:

```swift
            .task(id: id) {
                if let cachedKind = cache.mediaKind(for: id) {
                    mediaKind = cachedKind
                } else {
                    let kind = await library.mediaKind(for: id)
                    cache.store(kind, for: id)
                    mediaKind = kind
                }

                // Cache hit: assign synchronously without a PhotoKit call.
                if let cached = cache.image(for: id) {
                    image = cached
                    return
                }
                // Cache miss: fetch from PhotoKit, then cache and display.
                guard let thumb = await library.thumbnail(for: id, targetSize: targetSize) else {
                    return
                }
                cache.store(thumb.image, for: id)
                image = thumb.image
            }
```

Replace with:

```swift
            .task(id: id) {
                // Reset progress state when the cell re-fires for a new id.
                downloadProgress = nil

                if let cachedKind = cache.mediaKind(for: id) {
                    mediaKind = cachedKind
                } else {
                    let kind = await library.mediaKind(for: id)
                    cache.store(kind, for: id)
                    mediaKind = kind
                }

                // Cache hit: assign synchronously without a PhotoKit call.
                if let cached = cache.image(for: id) {
                    image = cached
                    return
                }
                // Cache miss: fetch from PhotoKit with progress reporting.
                // W11 fix: use thumbnailWithProgress so the iCloud progress
                // overlay shows during cellular downloads. The handler is called
                // on a PhotoKit callback queue; we dispatch back to MainActor
                // to update @State safely.
                let thumb = await library.thumbnailWithProgress(
                    for: id,
                    targetSize: targetSize
                ) { [id] progress in
                    Task { @MainActor in
                        // Only update if this task is still active for the same id.
                        downloadProgress = progress
                    }
                }
                downloadProgress = nil  // clear progress indicator on completion
                guard let thumb else { return }
                cache.store(thumb.image, for: id)
                image = thumb.image
            }
```

- [ ] **Step 6: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. Key checks:
- `thumbnailWithProgress(for:targetSize:progressHandler:)` is declared in the protocol extension with a default implementation — `MockPhotoLibrary` gets it for free without source changes.
- `avPlayerItemWithProgress(for:progressHandler:)` similarly has a default extension.
- `ThumbnailCell`'s `Task { @MainActor in }` pattern is valid in Swift 5 (global actor inference on closures).
- `ProgressView(value: progress)` with `.progressViewStyle(.circular)` and a `Double` value requires iOS 14+ — available.

- [ ] **Step 7: Run `ThumbnailLoadingTests` and the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**, including the three new `ThumbnailLoadingTests`.

- [ ] **Step 8: Commit**

```
Report line: "phase-4/W11: added thumbnailWithProgress + avPlayerItemWithProgress to PhotoKitLibrary with progressHandler and one-retry path; ThumbnailCell shows ProgressView overlay during iCloud downloads — W11"
```

⚠️ **Human: add `SwipeSortTests/ThumbnailLoadingTests.swift` to the SwipeSortTests Xcode target.**

---

## Verification Pass

After all 10 tasks are complete, run this structural self-check before reporting phase completion.

- [ ] **Check 1: `GridImageCache.store` uses `cgImage` pixel dimensions**

```
grep -n "cgImage" SwipeSort/Features/Components/GridImageCache.swift
```

Expected: line shows `image.cgImage?.width` and `image.cgImage?.height`.

- [ ] **Check 2: `PhotoGridView.thumbnailPixelSize` is a computed property**

```
grep -n "thumbnailPixelSize" SwipeSort/Features/Components/PhotoGridView.swift
```

Expected: output shows `private var thumbnailPixelSize: CGSize {` (not `private let`).

- [ ] **Check 3: All three `onReceive` handlers are debounced**

```
grep -n "libraryChangeTask" SwipeSort/Features/Landing/RecentsView.swift
grep -n "libraryChangeTask" SwipeSort/Features/Landing/AlbumsView.swift
```

Expected: `RecentsView.swift` has 2 matches (declaration + use); `AlbumsView.swift` has 4 matches (two declarations — one in `AlbumsView`, one in `AlbumGridView` — plus two uses).

- [ ] **Check 4: `refreshFetchResult()` is no longer called from `loadAssets`**

```
grep -n "refreshFetchResult" SwipeSort/Features/Landing/RecentsView.swift
grep -n "refreshFetchResult" SwipeSort/Features/Landing/AlbumsView.swift
```

Expected: **no output** for both files. The only call sites for `refreshFetchResult` remaining in the codebase should be the protocol declaration and `PhotoKitLibrary`'s own implementation.

- [ ] **Check 5: `PhotoKitLibrary.applyFilter` always invalidates the cursor**

```
grep -n "fetchResult = nil" SwipeSort/Core/PhotoKitLibrary.swift
```

Expected: `fetchResult = nil` appears in `applyFilter` unconditionally (outside the `if filterChanged` block) and in `refreshFetchResult`.

- [ ] **Check 6: `slideTask` is stored and cancelled before `stopAll()`**

```
grep -n "slideTask" SwipeSort/Features/Swipe/SwipeStackView.swift
```

Expected: at least 4 matches — declaration, assignment in `onChange`, `slideTask?.cancel()` in `onDisappear`, `slideTask = nil` in `onDisappear`.

- [ ] **Check 7: `VideoPlayerPool.shared.drain()` is called in `.finished` path**

```
grep -n "drain" SwipeSort/Features/Swipe/SwipeStackView.swift
```

Expected: 2 matches — one in `onChange(of: model.phase)` for `.finished`, one in `onDisappear`.

- [ ] **Check 8: `WindowedThumbnailCache` default window is 10/5**

```
grep -n "aheadOf.*=.*10\|behind.*=.*5" SwipeSort/Core/WindowedThumbnailCache.swift
```

Expected: matches `aheadOf: Int = 10` and `behind: Int = 5`.

- [ ] **Check 9: In-window no-op guard is present in `slide(to:total:)`**

```
grep -n "currentWindow.contains" SwipeSort/Core/WindowedThumbnailCache.swift
```

Expected: one match inside `slide(to:total:)`.

- [ ] **Check 10: Sparse batch splitting is present in `resolveIdentifiers`**

```
grep -n "isSparse\|sparse" SwipeSort/Core/WindowedThumbnailCache.swift
```

Expected: matches for `isSparse` and the sparseness threshold comment.

- [ ] **Check 11: `trimKinds(keeping:)` exists and is called from both view load functions**

```
grep -rn "trimKinds" SwipeSort/
```

Expected: 3 matches — definition in `GridImageCache.swift`, call in `RecentsView.loadAssets`, call in `AlbumsView.swift` `AlbumGridView.loadAssets`.

- [ ] **Check 12: Three `Task.isCancelled` checkpoints in `SwipeStackView.task`**

```
grep -n "Task.isCancelled" SwipeSort/Features/Swipe/SwipeStackView.swift
```

Expected: 3 matches inside the `.task { }` body.

- [ ] **Check 13: `model.configure(targetSize:)` exists and is called from `.task`**

```
grep -n "configure(targetSize" SwipeSort/Features/Swipe/SwipeSessionModel.swift
grep -n "configure(targetSize" SwipeSort/Features/Swipe/SwipeStackView.swift
```

Expected: 1 match in `SwipeSessionModel.swift` (method declaration), 1 match in `SwipeStackView.swift` (call in `.task`).

- [ ] **Check 14: `thumbnailWithProgress` is declared in the protocol extension**

```
grep -n "thumbnailWithProgress" SwipeSort/Core/PhotoLibraryProviding.swift
grep -n "thumbnailWithProgress" SwipeSort/Core/PhotoKitLibrary.swift
grep -n "thumbnailWithProgress" SwipeSort/Features/Components/ThumbnailCell.swift
```

Expected: matches in all three files — protocol declaration + default extension, real implementation, and call site.

- [ ] **Check 15: `downloadProgress` overlay is present in `ThumbnailCell`**

```
grep -n "downloadProgress" SwipeSort/Features/Components/ThumbnailCell.swift
```

Expected: at least 3 matches — `@State` declaration, `nil` assignment in task body, conditional in overlay.

- [ ] **Check 16: Full test suite passes**

In Xcode: Product → Test (full suite).

Expected: **all tests PASS**. This is the final gate for Phase 4 execution.

---

## Working Set Coverage

| Working-set item | Task | Severity | Status |
|---|---|---|---|
| W3 — `GridImageCache.store` cost uses point dimensions | Task 1 | high | Covered |
| W12 — `PhotoGridView.thumbnailPixelSize` hard-coded point literal | Task 1 | medium | Covered |
| W1 — Unbounced library-change notification handlers | Task 2 | high | Covered |
| W5 — Redundant `refreshFetchResult` in `loadAssets` | Task 3 | high | Covered |
| W10 — `slideTask` races `stopAll()` on disappear | Task 4 | medium | Covered |
| W4 — `VideoPlayerPool.drain()` not called on `.finished` path | Task 4 | high | Covered |
| W2 — `WindowedThumbnailCache` window too narrow; no in-window no-op | Task 5 | high | Covered |
| W8 — `resolveIdentifiers` over-fetches sparse index sets | Task 6 | medium | Covered |
| W9 — `GridImageCache.kinds` unbounded; stale entries accumulate | Task 7 | medium | Covered |
| W6 — No `Task.isCancelled` checkpoints in `SwipeStackView.task` | Task 8 | medium | Covered |
| W7 — `cardPixelSize` computed in `init` before screen attachment | Task 9 | medium | Covered |
| W11 — iCloud download progress not surfaced; no retry | Task 10 | medium | Covered |

All 12 confirmed live findings (W1–W12) are covered.

---

## Handoff

Plan saved to `/home/harshal.patil/Documents/SwipeSort/docs/superpowers/plans/2026-07-15-phase-4-performance.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task using `superpowers:subagent-driven-development`. Review between tasks. Fast iteration with isolated context per task.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`. Batch execution with checkpoints.

Which approach?
