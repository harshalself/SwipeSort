# Index-Driven Grid Implementation Plan

**Spec:** `docs/superpowers/specs/2026-07-16-index-driven-grid-design.md`

**Goal:** Replace the eager 500/1000-cap identifier arrays in `RecentsView` and `AlbumsView` with an index-driven `PhotoGridView` that renders any library size without truncation and without a "load more" UI. Match Apple Photos' scrolling model: total count is known instantly; individual identifiers and thumbnails materialize on-demand as cells appear.

**Architecture:** `PHFetchResult` already knows the count in O(1). `PhotoGridView` iterates `0..<totalCount` in a `LazyVGrid`; each `AsyncThumbnailCell` resolves its own identifier via `library.assetIdentifier(at: index)` on appear, then renders the existing `ThumbnailCell`. A parent-owned `generation: Int` counter, passed as a prop to every cell, forces re-resolution after library changes. The grid owns its own `WindowedThumbnailCache` (distinct from `SwipeStackView`'s per-session cache) and drives it from per-cell appear tracking. `GridSelectionBottomBar` "Select All" becomes "Select Visible" and operates on the resolved-ID subset.

**Tech Stack:** Swift 5.9+, SwiftUI, PhotoKit (`PHFetchResult`, `PHCachingImageManager`), Swift Testing framework.

## Global Constraints

- `PhotoLibraryProviding` protocol unchanged. No new methods added.
- `WindowedThumbnailCache` implementation unchanged — only new call sites.
- `ThumbnailCell` implementation unchanged — new `AsyncThumbnailCell` wraps it.
- No pagination UI ("load more" buttons, chunk boundaries) is introduced. Removing it is a goal, not a compromise.
- Both `TODO(pagination)` markers must be deleted, not just rephrased.
- `mock.identifiersCallRanges` must remain empty across a `loadCount()` call on a 10_000-count `MockPhotoLibrary` — this is the "no eager fetch" invariant.
- All new code is `@MainActor`-isolated to match the surrounding codebase.

---

## Task 1: `AsyncThumbnailCell` subview

**Files:**
- Create: `SwipeSort/Features/Components/AsyncThumbnailCell.swift`

**Interfaces:**
- Consumes: `PhotoLibraryProviding.assetIdentifier(at:)`, existing `ThumbnailCell`.
- Produces: `AsyncThumbnailCell(index:generation:library:cache:targetSize:isSelected:accessibilityIndex:onResolve:)` — the sole per-cell view used by `PhotoGridView` in Task 3.

- [ ] **Step 1: Write the file**

```swift
import SwiftUI

/// A grid cell that resolves its `AssetIdentifier` from an index on appear,
/// then delegates rendering to `ThumbnailCell`.
///
/// The `.task(id:)` key combines `generation` and `index` so a library-change
/// bump on `generation` forces every visible cell to re-resolve — the asset at
/// index N may be a different asset after a change.
///
/// While the identifier is in flight, the cell shows a solid neutral square.
/// The two-hop (id-resolve → thumbnail) is not a real cost: both calls are O(1)
/// against an in-memory `PHFetchResult`.
struct AsyncThumbnailCell: View {
    let index: Int
    let generation: Int
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
                Color(.secondarySystemBackground)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .task(id: "\(generation)-\(index)") {
            resolvedId = nil
            let id = await library.assetIdentifier(at: index)
            resolvedId = id
            if let id { onResolve(index, id) }
        }
    }
}
```

- [ ] **Step 2: Verify it builds (compile check via Xcode not available; sanity check by inspection)**

Confirm the file references only existing types (`PhotoLibraryProviding`, `GridImageCache`, `ThumbnailCell`, `AssetIdentifier`) and that the closure signature matches how `PhotoGridView` will call it in Task 3.

- [ ] **Step 3: Add to file-map**

Append one line to `docs/reviews/2026-07-13/.file-map.md` under Components describing `AsyncThumbnailCell.swift`. Bump the total file count.

- [ ] **Step 4: Add to FOLLOWUPS.md**

Add `AsyncThumbnailCell.swift` and (in Task 4 below) `LoadCountController.swift` to the "files added since Xcode project scaffold — needs target membership" list.

---

## Task 2: `LoadCountController` + tests

**Files:**
- Create: `SwipeSort/Features/Landing/LoadCountController.swift`
- Create: `SwipeSortTests/LoadCountControllerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @Observable
  @MainActor
  final class LoadCountController {
      private(set) var totalCount: Int = 0
      private(set) var hasIndexed: Bool = false
      private(set) var generation: Int = 0
      func refresh(from library: PhotoLibraryProviding, filter: SwipeFilter) async
  }
  ```
- Consumed by `RecentsView` and `AlbumGridView` in Task 3.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import SwipeSort

@Suite("LoadCountController")
@MainActor
struct LoadCountControllerTests {

    @Test("refresh does not eagerly fetch identifiers")
    func noEagerIdentifierFetch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.totalCount == 10_000)
        #expect(controller.hasIndexed == true)
        #expect(controller.generation == 1)
        #expect(mock.identifiersCallRanges.isEmpty,
                "loadCount() must not call identifiers(in:) — the grid resolves per-cell on demand")
    }

    @Test("each refresh bumps generation by exactly one")
    func generationIncrementsPerRefresh() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 100)
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)
        await controller.refresh(from: mock, filter: .unfiltered)
        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.generation == 3)
    }

    @Test("refresh requests authorization when notDetermined")
    func requestsAuthorizationWhenNotDetermined() async {
        let mock = MockPhotoLibrary(authorization: .notDetermined, assetCount: 5)
        mock.nextAuthorizationDecision = .authorized
        let controller = LoadCountController()

        await controller.refresh(from: mock, filter: .unfiltered)

        #expect(controller.totalCount == 5)
        let auth = await mock.currentAuthorization()
        #expect(auth == .authorized)
    }
}
```

- [ ] **Step 2: Write the implementation**

```swift
import Foundation
import Observation

/// Owns the per-view "total count + generation" state that drives the
/// index-driven grid.
///
/// `refresh(from:filter:)` re-reads `library.assetCount()` and bumps
/// `generation`. Bumping `generation` changes each `AsyncThumbnailCell`'s
/// `.task(id:)` key, forcing every visible cell to re-resolve its identifier
/// — the asset at any given index may have changed after a library edit.
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

    func refresh(from library: PhotoLibraryProviding, filter: SwipeFilter) async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.applyFilter(filter)
        totalCount = await library.assetCount()
        generation &+= 1
        hasIndexed = true
    }
}
```

- [ ] **Step 3: Add to file-map + FOLLOWUPS**

Add both new files (`LoadCountController.swift`, `LoadCountControllerTests.swift`) to `.file-map.md` and add the test file to the FOLLOWUPS Xcode-target-membership list.

---

## Task 3: Migrate `PhotoGridView`, `GridSelectionBottomBar`, `RecentsView`, `AlbumGridView`

**Files:**
- Modify: `SwipeSort/Features/Components/PhotoGridView.swift`
- Modify: `SwipeSort/Features/Components/GridSelectionInfra.swift`
- Modify: `SwipeSort/Features/Landing/RecentsView.swift`
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift`

**Interfaces:**
- Consumes: `AsyncThumbnailCell` (Task 1), `LoadCountController` (Task 2), unchanged `WindowedThumbnailCache`, unchanged `ThumbnailCell`, unchanged `GridImageCache`.
- Produces:
  ```swift
  struct PhotoGridView: View {
      let library: PhotoLibraryProviding
      let totalCount: Int
      let generation: Int
      let imageCache: GridImageCache
      @Binding var isSelecting: Bool
      @Binding var selectedIds: Set<AssetIdentifier>
      let onTapAsset: (Int, AssetIdentifier) -> Void
      let onRequestMove: ([AssetIdentifier]) -> Void
  }

  struct GridSelectionBottomBar: View {
      @Binding var selectedIds: Set<AssetIdentifier>
      let visibleIds: [AssetIdentifier]
      let onMoveTapped: () -> Void
  }
  ```

- [ ] **Step 1: Rewrite `PhotoGridView.swift`**

```swift
import SwiftUI

/// A reusable 3-column photo grid with drag-range multi-selection.
///
/// The parent supplies `totalCount` and `generation` from a
/// `LoadCountController`. Each cell resolves its own identifier on appear
/// via `AsyncThumbnailCell`; identifiers accumulate in `indexToId` as cells
/// materialize, and both the drag-range gesture and the "Select Visible"
/// button operate on that resolved set. Bumping `generation` forces every
/// visible cell to re-resolve, which is how library-change refreshes
/// propagate without an eager identifier fetch.
///
/// The grid owns a `WindowedThumbnailCache` for prewarming; per-cell
/// `.onAppear` maintains `visibleIndices`, and changes to
/// `visibleIndices.min()` drive `slide(to:total:)`. `onDisappear` calls
/// `stopAll()` to release cache memory when the view is torn down.
struct PhotoGridView: View {
    let library: PhotoLibraryProviding
    let totalCount: Int
    let generation: Int
    let imageCache: GridImageCache
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<AssetIdentifier>
    let onTapAsset: (Int, AssetIdentifier) -> Void
    let onRequestMove: ([AssetIdentifier]) -> Void

    @State private var indexToId: [Int: AssetIdentifier] = [:]
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var visibleIndices: Set<Int> = []
    @State private var thumbnailCache: WindowedThumbnailCache?
    @State private var lastRenderedGeneration: Int = -1
    @State private var dragStartIndex: Int? = nil
    @State private var dragStartSelectionState = true

    private let columns = [
        GridItem(.adaptive(minimum: 115), spacing: 2)
    ]
    private var thumbnailPixelSize: CGSize {
        PixelSize.from(points: CGSize(width: 400, height: 400))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<totalCount, id: \.self) { index in
                    AsyncThumbnailCell(
                        index: index,
                        generation: generation,
                        library: library,
                        cache: imageCache,
                        targetSize: thumbnailPixelSize,
                        isSelected: cellSelection(at: index),
                        accessibilityIndex: index,
                        onResolve: { i, id in
                            indexToId[i] = id
                        }
                    )
                    .contentShape(Rectangle())
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: GridCellFramePreferenceKey.self,
                                value: [index: proxy.frame(in: .named("SelectGridSpace"))]
                            )
                        }
                    }
                    .accessibilityIdentifier("ThumbnailCell-\(index)")
                    .onAppear {
                        visibleIndices.insert(index)
                    }
                    .onDisappear {
                        visibleIndices.remove(index)
                    }
                    .onTapGesture {
                        guard let id = indexToId[index] else { return }
                        if isSelecting {
                            if selectedIds.contains(id) {
                                selectedIds.remove(id)
                            } else {
                                selectedIds.insert(id)
                            }
                        } else {
                            onTapAsset(index, id)
                        }
                    }
                }
            }
            .coordinateSpace(name: "SelectGridSpace")
            .onPreferenceChange(GridCellFramePreferenceKey.self) { frames in
                cellFrames = frames
            }
            .gesture(
                isSelecting ?
                DragGesture(minimumDistance: 12, coordinateSpace: .named("SelectGridSpace"))
                    .onChanged { value in
                        guard let idx = gridIndex(at: value.location, in: cellFrames) else { return }
                        if dragStartIndex == nil {
                            dragStartIndex = idx
                            if let startId = indexToId[idx] {
                                dragStartSelectionState = !selectedIds.contains(startId)
                            } else {
                                dragStartSelectionState = true
                            }
                        }
                        guard let start = dragStartIndex else { return }
                        let lower = min(start, idx)
                        let upper = max(start, idx)
                        for i in lower...upper {
                            guard let id = indexToId[i] else { continue }
                            if dragStartSelectionState {
                                selectedIds.insert(id)
                            } else {
                                selectedIds.remove(id)
                            }
                        }
                    }
                    .onEnded { _ in
                        dragStartIndex = nil
                    }
                : nil
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                GridSelectionBottomBar(
                    selectedIds: $selectedIds,
                    visibleIds: resolvedIdsInIndexOrder
                ) {
                    onRequestMove(Array(selectedIds))
                }
            }
        }
        .onAppear {
            if thumbnailCache == nil {
                thumbnailCache = WindowedThumbnailCache(
                    library: library,
                    targetSize: thumbnailPixelSize
                )
            }
        }
        .onDisappear {
            thumbnailCache?.stopAll()
        }
        .onChange(of: visibleIndices.min() ?? 0) { _, newMin in
            let cache = thumbnailCache
            let total = totalCount
            Task { await cache?.slide(to: newMin, total: total) }
        }
        .onChange(of: generation) { _, _ in
            indexToId.removeAll(keepingCapacity: true)
        }
    }

    /// The resolved identifiers sorted by their originating index, so
    /// "Select Visible" preserves grid order in the selected set.
    private var resolvedIdsInIndexOrder: [AssetIdentifier] {
        indexToId.keys.sorted().compactMap { indexToId[$0] }
    }

    private func cellSelection(at index: Int) -> Bool? {
        guard isSelecting else { return nil }
        guard let id = indexToId[index] else { return false }
        return selectedIds.contains(id)
    }
}
```

- [ ] **Step 2: Rewrite the top of `GridSelectionInfra.swift`**

Replace only the `GridSelectionBottomBar` struct (keep `GridCellFramePreferenceKey` and `gridIndex(at:in:)` intact):

```swift
/// The bottom toolbar shown while multi-select is active in a grid view.
///
/// Provides "Select Visible / Deselect All" and a "Move (n)" action. In the
/// index-driven grid, `visibleIds` is the set of identifiers currently
/// resolved by on-screen cells — not every identifier in the library. This
/// mirrors Photos.app: bulk-select operates on what you can see and drag
/// through, not on an unbounded fetch.
struct GridSelectionBottomBar: View {
    @Binding var selectedIds: Set<AssetIdentifier>
    let visibleIds: [AssetIdentifier]
    let onMoveTapped: () -> Void

    private var allVisibleSelected: Bool {
        !visibleIds.isEmpty && visibleIds.allSatisfy { selectedIds.contains($0) }
    }

    var body: some View {
        HStack {
            Button(allVisibleSelected ? "Deselect All" : "Select Visible") {
                if allVisibleSelected {
                    for id in visibleIds { selectedIds.remove(id) }
                } else {
                    selectedIds.formUnion(visibleIds)
                }
            }
            .font(.subheadline.weight(.medium))

            Spacer()

            Button(action: onMoveTapped) {
                Label("Move (\(selectedIds.count))", systemImage: "folder.fill.badge.plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
```

- [ ] **Step 3: Migrate `RecentsView.swift`**

Replace `@State private var assetIds` + `@State private var hasIndexed` + `@State private var filter` state with a `LoadCountController`, delete `TODO(pagination)`:

```swift
import SwiftUI
import Combine

struct RecentsView: View {
    let library: PhotoLibraryProviding

    @State private var loadCount = LoadCountController()
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false
    @State private var libraryChangeTask: Task<Void, Never>?

    @State private var imageCache = GridImageCache()

    var body: some View {
        NavigationStack {
            Group {
                if !loadCount.hasIndexed {
                    VStack {
                        Spacer()
                        ProgressView("Indexing library…").padding()
                        Spacer()
                    }
                } else if loadCount.totalCount == 0 {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No photos found.")
                            .font(.headline)
                        Text("Try adjusting the filter, or grant library access first.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .accessibilityIdentifier("EmptyStateView")
                } else {
                    PhotoGridView(
                        library: library,
                        totalCount: loadCount.totalCount,
                        generation: loadCount.generation,
                        imageCache: imageCache,
                        isSelecting: $isSelecting,
                        selectedIds: $selectedIds,
                        onTapAsset: { index, id in
                            swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                        },
                        onRequestMove: { _ in
                            showingAlbumPicker = true
                        }
                    )
                }
            }
            .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : "Recents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button("Cancel") {
                            isSelecting = false
                            selectedIds.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if loadCount.totalCount > 0 {
                            Button(isSelecting ? "Done" : "Select") {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIds.removeAll()
                                }
                            }
                        }
                        Button {
                            showingFilter = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityIdentifier("FilterButton")
                    }
                }
            }
            .fullScreenCover(item: $swipeContext, onDismiss: {
                Task { await loadCount.refresh(from: library, filter: filter) }
            }) { context in
                SwipeStackView(library: library, filter: filter, initialIndex: context.initialIndex, initialAssetId: context.initialAssetId)
            }
            .sheet(isPresented: $showingFilter, onDismiss: {
                Task { await loadCount.refresh(from: library, filter: filter) }
            }) {
                FilterSheet(filter: $filter, onFilterChange: {
                    Task { await loadCount.refresh(from: library, filter: filter) }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerSheet(
                    library: library,
                    selectedCount: selectedIds.count,
                    sourceAlbumId: nil
                ) { targetAlbum in
                    let ids = Array(selectedIds)
                    _ = await library.moveAssets(ids, fromAlbumId: nil, toAlbumId: targetAlbum.id)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    isSelecting = false
                    selectedIds.removeAll()
                    await loadCount.refresh(from: library, filter: filter)
                }
            }
            .task { await loadCount.refresh(from: library, filter: filter) }
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                libraryChangeTask?.cancel()
                libraryChangeTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    await loadCount.refresh(from: library, filter: filter)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Migrate `AlbumGridView` inside `AlbumsView.swift`**

Apply the same migration pattern to `AlbumGridView`. Delete `TODO(pagination)`. Only `AlbumGridView` changes; the outer `AlbumsView` (album list) is unchanged. Full new body of `AlbumGridView`:

```swift
struct AlbumGridView: View {
    let album: UserAlbum
    let library: PhotoLibraryProviding

    @State private var loadCount = LoadCountController()
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var imageCache = GridImageCache()
    @State private var scopedLibrary: PhotoLibraryProviding?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false
    @State private var libraryChangeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !loadCount.hasIndexed {
                VStack {
                    Spacer()
                    ProgressView("Loading photos…").padding()
                    Spacer()
                }
            } else if loadCount.totalCount == 0 {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    Text("No photos found.")
                        .font(.headline)
                    Text("Try adjusting the filter or add photos to this album.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else {
                PhotoGridView(
                    library: scopedLibrary ?? library,
                    totalCount: loadCount.totalCount,
                    generation: loadCount.generation,
                    imageCache: imageCache,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    onTapAsset: { index, id in
                        swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                    },
                    onRequestMove: { _ in
                        showingAlbumPicker = true
                    }
                )
            }
        }
        .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if loadCount.totalCount > 0 {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedIds.removeAll()
                            }
                        }
                    }
                    Button {
                        showingFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .fullScreenCover(item: $swipeContext, onDismiss: {
            Task { await refreshScopedCount() }
        }) { context in
            SwipeStackView(
                library: scopedLibrary ?? library,
                filter: filter,
                albumTitle: album.title,
                initialIndex: context.initialIndex,
                initialAssetId: context.initialAssetId
            )
        }
        .sheet(isPresented: $showingFilter, onDismiss: {
            Task { await refreshScopedCount() }
        }) {
            FilterSheet(filter: $filter, onFilterChange: {
                Task { await refreshScopedCount() }
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerSheet(
                library: library,
                selectedCount: selectedIds.count,
                sourceAlbumId: album.id
            ) { targetAlbum in
                let ids = Array(selectedIds)
                _ = await library.moveAssets(ids, fromAlbumId: album.id, toAlbumId: targetAlbum.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isSelecting = false
                selectedIds.removeAll()
                await refreshScopedCount()
            }
        }
        .task(id: album.id) {
            scopedLibrary = library.scoped(toAlbumId: album.id)
            await refreshScopedCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
            libraryChangeTask?.cancel()
            libraryChangeTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await refreshScopedCount()
            }
        }
    }

    private func refreshScopedCount() async {
        let s = scopedLibrary ?? library
        await loadCount.refresh(from: s, filter: filter)
    }
}
```

- [ ] **Step 5: Update `.file-map.md` — component surface changed**

Refresh the entry for `PhotoGridView.swift`, `GridSelectionInfra.swift`, `RecentsView.swift`, and `AlbumsView.swift` to reflect the new prop signatures. Bump line counts (`PhotoGridView` will grow ~30 lines; `RecentsView` shrinks; `AlbumsView`'s grid section shrinks).

- [ ] **Step 6: Verify grep — no lingering references to old shape**

```bash
grep -rn "TODO(pagination)" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
grep -rn "assetIds: \[AssetIdentifier\]" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
grep -rn "allIds:" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
grep -rn "Select All" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
```

Expected: all four return zero hits inside `SwipeSort/`.

---

## Task 4: `AsyncThumbnailCell` behavior test

**Files:**
- Create: `SwipeSortTests/AsyncThumbnailCellTests.swift`

The SwiftUI view itself is not rendered in tests (no ViewInspector). Instead, we test the observable contract via `MockPhotoLibrary` directly — the same identifier-resolution call the cell makes on appear.

- [ ] **Step 1: Write the test**

```swift
import Testing
@testable import SwipeSort

@Suite("AsyncThumbnailCell behavior")
@MainActor
struct AsyncThumbnailCellTests {

    @Test("assetIdentifier(at:) resolves indices beyond the old 500/1000 caps")
    func resolvesFarBeyondOldCaps() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)

        let id0 = await mock.assetIdentifier(at: 0)
        let id500 = await mock.assetIdentifier(at: 500)
        let id1000 = await mock.assetIdentifier(at: 1_000)
        let id9999 = await mock.assetIdentifier(at: 9_999)

        #expect(id0 == AssetIdentifier("mock-asset-0"))
        #expect(id500 == AssetIdentifier("mock-asset-500"))
        #expect(id1000 == AssetIdentifier("mock-asset-1000"))
        #expect(id9999 == AssetIdentifier("mock-asset-9999"))
    }

    @Test("assetIdentifier(at:) returns nil for out-of-range indices")
    func nilBeyondCount() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10)
        let id = await mock.assetIdentifier(at: 10)
        #expect(id == nil)
    }

    @Test("resolving many indices does not trigger a batched identifiers(in:) fetch")
    func perIndexResolutionSkipsBatching() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 10_000)

        for i in stride(from: 0, to: 10_000, by: 137) {
            _ = await mock.assetIdentifier(at: i)
        }

        #expect(mock.identifiersCallRanges.isEmpty,
                "per-cell resolution must go through assetIdentifier(at:), never identifiers(in:)")
    }
}
```

- [ ] **Step 2: Add to FOLLOWUPS.md**

Add `AsyncThumbnailCellTests.swift` to the Xcode-target-membership list.

---

## Task 5: Regression + integration touch-up

**Files:**
- Modify (if needed): existing test files that referenced the old `assetIds`-based `PhotoGridView` signature or `GridSelectionBottomBar.allIds`.

- [ ] **Step 1: Grep for stale test references**

```bash
grep -rn "PhotoGridView(" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/
grep -rn "GridSelectionBottomBar(" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/
grep -rn "\.allIds" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/
```

- [ ] **Step 2: Fix any hits**

If any test constructs `PhotoGridView` or `GridSelectionBottomBar` directly, update it to the new API. If the test only depends on identifiers arriving via the drag path, it should still pass since drag continues to work on `indexToId`. Note in comments if a test needs a follow-up because it depended on the old "Select All → every id in library" behavior.

- [ ] **Step 3: Final grep sanity pass**

```bash
grep -rn "TODO(pagination)" /home/harshal.patil/Documents/SwipeSort/
grep -rn "min(count, 500)" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
grep -rn "min(count, 1000)" /home/harshal.patil/Documents/SwipeSort/SwipeSort/
```

All three: zero hits.

---

## Success criteria (from spec, restated)

1. Both `TODO(pagination)` markers removed.
2. `LoadCountControllerTests.noEagerIdentifierFetch` passes: `mock.identifiersCallRanges` remains empty after `refresh` on a 10 000-count mock.
3. `AsyncThumbnailCellTests.resolvesFarBeyondOldCaps` passes: index 9 999 resolves to `AssetIdentifier("mock-asset-9999")`.
4. `LoadCountControllerTests.generationIncrementsPerRefresh` passes: `generation` bumps by exactly 1 per refresh.
5. `PhotoGridView` owns a `WindowedThumbnailCache` and drives `slide(to:total:)` from cell-appear tracking; `stopAll()` fires on `onDisappear`.
6. Existing multi-select tests either pass unchanged (drag path) or are updated to the "Select Visible" semantic.

## Notes for the implementer (myself, inline)

- **No git commits** — the working directory is not a git repo in this environment. Skip the "Commit" step SDD templates would normally include.
- **Build verification** — I can't run Xcode from this environment. The verification steps are grep-based and inspection-based.
- **File-map + FOLLOWUPS** — update these as we go, one edit per file, batched at the end of each task.
