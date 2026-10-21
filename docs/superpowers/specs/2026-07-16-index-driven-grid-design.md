# Index-Driven Grid — Design Spec

**Date:** 2026-07-16
**Replaces:** `TODO(pagination)` in `RecentsView.swift:144` and `AlbumsView.swift:264`
**Approach:** Apple-style. `PHFetchResult` is already a lazy cursor; the grid iterates by index, cells fetch their identifier + thumbnail on appear, `WindowedThumbnailCache` continues to pre-warm.

## Goal

Replace the eager 500/1000-cap identifier arrays in `RecentsView` and `AlbumsView` with an index-driven `PhotoGridView` that renders any library size without truncation and without a "load more" UI. Match Apple Photos' scrolling model: total count is known instantly; individual identifiers and thumbnails materialize on-demand as cells appear.

## Motivation

Today both `loadAssets()` implementations do:
```swift
let count = await library.assetCount()
let limit = min(count, 500)                       // or 1000 for albums
assetIds = await library.identifiers(in: 0..<limit)
```

The cap exists because `identifiers(in:)` is O(range.count) — larger ranges made initial paint sluggish. But `PHFetchResult` already knows the count in O(1) and returns individual assets in O(1) via `object(at:)`. Materializing 500 identifiers up front is unnecessary; SwiftUI's `LazyVGrid` only instantiates on-screen cells anyway.

Removing the eager fetch:
- eliminates silent truncation (users with >500 recent photos see all their photos)
- reduces initial paint time (no 500-item fetch before first render)
- makes both `TODO(pagination)` markers obsolete
- keeps memory O(visible rows) regardless of library size

## Non-goals

- **Not implementing pagination.** No "load more" button, no chunk boundaries. If the user has 50k photos, all 50k are addressable from frame one; only ~20 cells materialize as SwiftUI views.
- **Not changing the swipe deck.** `SwipeSessionModel` already uses the fetch cursor directly and has no truncation problem.
- **Not changing `WindowedThumbnailCache`.** The class stays as-is — only new call sites are added from `PhotoGridView`'s scroll tracker.
- **Not changing multi-select semantics.** Drag-range selection continues to work; the "select all" affordance in `GridSelectionBottomBar` gets clarified below.

## Architecture

### Data-source shape

`PhotoGridView` currently takes `assetIds: [AssetIdentifier]`. The new shape:

```swift
struct PhotoGridView: View {
    let library: PhotoLibraryProviding
    let totalCount: Int                       // ← from library.assetCount()
    let imageCache: GridImageCache
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<AssetIdentifier>
    let onTapAsset: (Int, AssetIdentifier) -> Void
    let onRequestMove: ([AssetIdentifier]) -> Void
    ...
}
```

The parent view (`RecentsView` / `AlbumsView`) reads `totalCount` in its existing `loadAssets()` (renamed to `loadCount()`), and passes it in. No identifier array is materialized eagerly.

### Cell dispatch

`ForEach(0..<totalCount, id: \.self)` iterates indices. Each cell is an `AsyncThumbnailCell`. The cell's `.task` key combines `index` *and* a parent-provided `generation` counter so that when the library changes (see §Live updates), every visible cell re-resolves its ID — the underlying asset at index N may now be a different asset:

```swift
struct AsyncThumbnailCell: View {
    let index: Int
    let generation: Int                          // bump → force re-resolve
    let library: PhotoLibraryProviding
    let cache: GridImageCache
    let targetSize: CGSize
    let isSelected: Bool?
    let accessibilityIndex: Int
    let onResolve: (Int, AssetIdentifier) -> Void

    @State private var resolvedId: AssetIdentifier?

    var body: some View {
        Group {
            if let id = resolvedId {
                ThumbnailCell(
                    id: id,
                    library: library,
                    cache: cache,
                    targetSize: targetSize,
                    isSelected: isSelected,
                    accessibilityIndex: accessibilityIndex
                )
            } else {
                Color(.secondarySystemBackground)   // solid placeholder
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: "\(generation)-\(index)") {
            resolvedId = nil                        // clear stale ID from prior generation
            let id = await library.assetIdentifier(at: index)
            resolvedId = id
            if let id { onResolve(index, id) }
        }
    }
}
```

While `library.assetIdentifier(at:)` is in flight, the cell shows a neutral gray square. Once the identifier resolves, the existing `ThumbnailCell` takes over — its `.task` fires `library.thumbnail(for:targetSize:)` and populates `GridImageCache` on completion. The two-hop is not a real cost: both calls are O(1) and both are already `@MainActor`-isolated hops off a `PHFetchResult` that lives entirely in memory.

**Loading state (decision):** solid `Color(.secondarySystemBackground)` placeholder. Not a skeleton shimmer (extra timers per visible cell) and not blur-up (doubles thumbnail requests). Matches what `RecentsView` already does when its identifier array is empty.

### Selection and drag-range gesture

Drag-range selection today reads `assetIds[i]` inside the drag `.onChanged`. The new grid resolves the ID from a small **index → id** map that `AsyncThumbnailCell` populates as it resolves. `PhotoGridView` owns that map as `@State`.

```swift
@State private var indexToId: [Int: AssetIdentifier] = [:]
```

`AsyncThumbnailCell` writes to this map via a callback prop (`onResolve: (Int, AssetIdentifier) -> Void`) rather than reading from a shared `@Binding` — this keeps the cell views cheap.

The drag gesture then looks up IDs it needs from `indexToId`. If the user drags across an index whose ID hasn't resolved yet (very rare — cells materialize before they're visible), the drag simply skips that index for this drag tick; subsequent ticks pick it up as the ID resolves.

**Rationale:** Drag-range selection requires an ID to add to `selectedIds`. Since drag operates in a small viewport window, only IDs for currently-visible cells need to be known — which is exactly what `AsyncThumbnailCell` has already resolved. Attempting to bulk-materialize IDs on drag start would re-introduce the very truncation we're removing.

### Select-all semantics

Today `GridSelectionBottomBar` accepts `allIds: [AssetIdentifier]` for its "Select All" button. In the new world, materializing every ID for a 50k-photo library defeats the purpose.

Two paths:
1. **"Select All" limited to currently-resolved IDs.** Clarify the button label to "Select Visible" and only select IDs present in `indexToId`.
2. **True "Select All" via an all-selected sentinel.** Add a boolean to the parent's selection state ("all selected"); the parent iterates the fetch cursor lazily when performing the bulk operation.

**Decision: Path 1 for this refactor.** Path 2 is a larger UX shift (Photos.app doesn't offer bulk-select-all either — it's finger-drag only) and would break the existing `moveAssets` / bulk-delete contracts that operate on `[AssetIdentifier]`. Rename the button "Select Visible" for clarity.

Existing tests that assert on `GridSelectionBottomBar.allIds` will need to adopt the new semantic (they select from what the grid has materialized, not from a synthetic 500-count).

### Live updates (mid-scroll library changes)

Today's implementation subscribes to `PhotoLibraryChangePublisher.didChangeNotification`, debounces 500 ms, and calls `loadAssets()`. That pattern is preserved with two additions:

1. `loadCount()` re-reads `library.assetCount()` and updates `totalCount`.
2. `loadCount()` also increments a `@State private var generation: Int` counter on the parent view, which is threaded down to every `AsyncThumbnailCell` as a prop. Bumping `generation` changes each cell's `.task(id:)` key, which forces every visible cell to clear its `resolvedId` and re-resolve.

**Why the generation counter is necessary:** `.task(id: index)` on its own only re-fires when `index` changes. If the underlying asset at index N is different after a library change (e.g. photo at index 5 was deleted, so what was at index 6 is now at index 5), the cell at `index: 5` would still show the old ID because 5 hasn't changed. The generation counter is what invalidates the cache of `.task` results.

**Cache correctness:** `GridImageCache` is keyed by `AssetIdentifier`, not by index, so stale thumbnails don't leak across a library change. `imageCache.trimKinds(keeping:)` is still called after `loadCount()`, but with the currently-resolved IDs from `indexToId` — bounded to visible-plus-window, not the full library. `indexToId` is cleared alongside the generation bump so stale index-to-id mappings don't survive a library change.

### `WindowedThumbnailCache` integration

`WindowedThumbnailCache.slide(to:total:)` already operates on indices and internally calls `library.identifiers(in:)` for the window. It gains no new responsibility.

**Ownership:** `PhotoGridView` owns a `@State private var thumbnailCache: WindowedThumbnailCache?` lazily constructed on first appear with the same `targetSize` used by the cells. This is different from `SwipeStackView`, which creates one per swipe session — the grid's cache lives for the grid's lifetime, tears down on `onDisappear`. Rationale: the parent view (`RecentsView` / `AlbumsView`) already owns `GridImageCache` and doesn't need a second cache-management concern; the grid is the only place that knows the visible-window scroll position.

**Scroll tracking:** `PhotoGridView` adds a scroll-position tracker. On iOS 17+ this uses `.onScrollGeometryChange(for: Int.self)` extracting `visibleRect.minY / rowHeight` as `firstVisibleIndex`; the fallback (< iOS 17) uses per-cell `.onAppear` recording the min visible index into an `@State`. On each change, the view fires `Task { await thumbnailCache?.slide(to: firstVisibleIndex, total: totalCount) }`. `onDisappear` calls `thumbnailCache?.stopAll()`.

**Not doing:** replacing `WindowedThumbnailCache` with a per-cell prefetch. The centralized cache is what makes scroll performance good; each cell just consumes its own thumbnail.

## File-level changes

**Modified:**
- `SwipeSort/Features/Components/PhotoGridView.swift` — replace `assetIds` prop with `totalCount + library`. Add `AsyncThumbnailCell` subview and `indexToId` state. Wire scroll-position → `WindowedThumbnailCache.slide` if a cache instance is provided.
- `SwipeSort/Features/Landing/RecentsView.swift` — remove `assetIds: [AssetIdentifier]` state and the 500-cap `loadAssets()`. Replace with `totalCount: Int` state and `loadCount()`. Delete `TODO(pagination)`.
- `SwipeSort/Features/Landing/AlbumsView.swift` — same as RecentsView. Delete `TODO(pagination)`.
- `SwipeSort/Features/Components/GridSelectionBottomBar.swift` — rename "Select All" → "Select Visible"; update the callback to receive `Set<AssetIdentifier>` (whatever's resolved) rather than iterating a full list.

**New:**
- `SwipeSort/Features/Components/AsyncThumbnailCell.swift` — one file, ~60 lines. Owns per-cell ID resolution.

**Tests:**
- `SwipeSortTests/AsyncThumbnailCellTests.swift` (new) — unit-test the cell in isolation without rendering the SwiftUI view. Test surface is a small helper that exercises the cell's resolution logic:
  - Given `MockPhotoLibrary(assetCount: 10_000)` and `index = 9_999`, `library.assetIdentifier(at:)` returns `AssetIdentifier("mock-asset-9999")` — proves the cursor addresses beyond the old caps.
  - Given the same mock, bumping the `generation` param re-invokes `assetIdentifier(at:)` on a fresh cell (asserted via `MockPhotoLibrary` tracking calls).
- `SwipeSortTests/IndexDrivenGridBehaviorTests.swift` (new) — test the observable contract via `MockPhotoLibrary`, no SwiftUI rendering:
  - After a `loadCount()` call for a 10_000-count mock, `mock.identifiersCallRanges` is empty (no eager identifiers fetch happened) — this is the "no truncation, no eager fetch" invariant.
  - After a library-change notification followed by `loadCount()`, the parent's `generation` counter increments by exactly 1 per debounced event. (Test via a small extracted `LoadCountController` struct — see plan.)
- Update `RecentsView` / `AlbumsView` scoped tests as needed to adopt the new `totalCount` API surface. Existing multi-select drag tests continue to hit `PhotoGridView` and pass since the drag mechanism is unchanged.

**Extraction for testability:** The `loadCount + generation bump` logic on the parent view is extracted into a small `@MainActor` struct or free function so it can be tested without rendering `RecentsView` / `AlbumsView`. Plan will specify the exact seam.

## Success criteria

1. `TODO(pagination)` markers removed from both files.
2. `mock.identifiersCallRanges` remains empty across a `loadCount()` on a 10_000-count mock — proves no eager identifier fetch happens for the full library.
3. `AsyncThumbnailCell` at `index = 9_999` resolves to `AssetIdentifier("mock-asset-9999")`.
4. A `PhotoLibraryChangePublisher.didChangeNotification` event increments the parent's `generation` counter exactly once (per debounce window).
5. `WindowedThumbnailCache` receives `slide(to:total:)` calls from the grid's scroll tracker.
6. Existing multi-select tests pass with the renamed "Select Visible" semantics.

## Open risks

- **`.task(id: "\(generation)-\(index)")` fires on every appear.** If a cell scrolls in-out-in rapidly during ballistic scroll, we may fire N identifier fetches for the same (generation, index) pair. `library.assetIdentifier(at:)` is O(1) in-memory so the cost is a few microseconds per call, but the `Task` allocation isn't free. Acceptable for v1; if profiling shows it as a hotspot, add a per-cell `@State` guard on `resolvedId != nil`.
- **Album variant (`AlbumsView`) uses `scopedLibrary`.** The scoped library instance changes when the album changes. `AsyncThumbnailCell` receives `library` as a `let`, so a re-scope forces the whole grid to redraw. Same behavior today — no regression.
- **Empty state.** `totalCount == 0` shows the existing "No photos found" copy. Unchanged from today.
- **`identifiersCallRanges` invariant is a passive check.** It asserts we don't do an eager 0..<N fetch; it doesn't assert `WindowedThumbnailCache` is doing its job. Test #5 (`slide(to:total:)` was called) covers the positive side.

## Rejected alternatives

- **Load-more button.** Anti-pattern for a photo grid; Apple Photos doesn't use it; more code for worse UX.
- **Chunked infinite scroll.** Same effect as this design but with visible chunk boundaries and code to detect "near bottom". Just noise on top of what SwiftUI already gives us for free.
- **Pre-resolve all IDs into an array once on first appear.** Would work for 10k but not for 100k; puts a linear-cost step back where we're trying to remove it.
