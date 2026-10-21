# Phase 3 — Shared grid + architecture cleanup: working set

**Re-verified:** 2026-07-15 (post Phase 1 + Phase 2)
**Source review:** docs/reviews/2026-07-13/
**Depends on:** Phase 1 complete (decision-lifecycle) + Phase 2 complete (concurrency/Sendable)

## Summary

- In-scope findings considered: 10 (architecture.md F1–F5, F9, F10, F13, F14; Phase 2 reroute correctness F11)
- Still present: 8 (W1–W8)
- Partially fixed: 0
- Already fixed: 0
- Rerouted to other phase: 2 (F6/F7 → Phase 7; F8/F11 routing clarified below)
- New architecture issues surfaced by re-verify: 3 (N1–N3)

---

## Working set — items to fix in Phase 3

### W1 — Shared grid primitives trapped inside `AlbumPickerSheet.swift` [ORIGIN: architecture.md F1, SEVERITY: high]
- **File:** SwipeSort/Features/Landing/AlbumPickerSheet.swift:153–212
- **Status:** still-present
- **What:** `GridSelectionBottomBar` (line 156), `GridCellFramePreferenceKey` (line 195), and `gridIndex` (line 205) are defined after the `AlbumPickerSheet` closing brace in a file named for a different concept. Both `RecentsView` (lines 125, 145, 152, 207) and `AlbumGridView` (lines 183, 202, 209, 264) import these symbols from this file by compilation-unit proximity, not by any explicit modular grouping.
- **Failure scenario:** A developer building a third grid view looks in `Features/Components/`, `Features/Landing/`, or even `Core/` but not inside a sheet implementation file. They duplicate `GridCellFramePreferenceKey` with independently maintained `reduce` logic, causing silent merge collisions in SwiftUI's preference graph — two keys with the same `defaultValue` but separate reduction passes produce non-deterministic merged state on complex layouts.
- **Fix direction:** Create `SwipeSort/Features/Components/GridSelectionInfra.swift` and move `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, and `gridIndex` there. `AlbumPickerSheet.swift` retains only `AlbumPickerSheet` and its private helpers. No other callers need changes — the symbols are module-scoped.
- **Depends on:** W3 (W3 also moves `GridImageCache` to the same new `Components/` group; these should be one coherent extraction commit to avoid a half-created `Components/` directory)

---

### W2 — `AlbumGridView` fully duplicates the `RecentsView` grid+selection body [ORIGIN: architecture.md F2, SEVERITY: high]
- **File:** SwipeSort/Features/Landing/AlbumsView.swift:123–334, SwipeSort/Features/Landing/RecentsView.swift:60–262
- **Status:** still-present
- **What:** Both views carry identical `@State` clusters (`isSelecting`, `selectedIds`, `showingAlbumPicker`, `cellFrames`, `dragStartIndex`, `dragStartSelectionState`, `imageCache`; `columns`; `thumbnailPixelSize`) and an identical ~60-line `DragGesture` body inside a `LazyVGrid`. The only structural differences are: (a) `AlbumGridView` uses `getScopedLibrary()` as its `ThumbnailCell.library`, `RecentsView` passes `library` directly; (b) `AlbumGridView` sets an asset limit of 1000, `RecentsView` uses 500; (c) `RecentsView` applies `.accessibilityIdentifier("ThumbnailCell-\(index)")` per cell, `AlbumGridView` does not. The divergence in (c) is an existing one-sided fix: UI tests targeting Albums silently miss all individual cells.
- **Failure scenario:** Any fix to the drag-selection gesture (e.g. fixing off-by-one in the range `lower...upper` at AlbumsView.swift:216) must be applied in two files. A one-sided fix has already landed (accessibility identifiers); this pattern will continue with every future grid enhancement.
- **Fix direction:** Extract a `PhotoGridView` composite that accepts `assetIds: [AssetIdentifier]`, `library: PhotoLibraryProviding`, `imageCache: GridImageCache`, `assetLimit: Int`, `sourceAlbumId: String?`, and callbacks `onTapAsset(index:id:)` / `onBulkMove(ids:)`. Move the `@State` selection cluster, the `LazyVGrid` loop, and the `DragGesture` body into `PhotoGridView`. Both `RecentsView` and `AlbumGridView` delegate their grid body to this shared view; they retain only their `NavigationStack`, toolbar, `loadAssets`, and filter state. The `.accessibilityIdentifier("ThumbnailCell-\(index)")` lives once in `PhotoGridView`.
- **Depends on:** W1 (the `GridCellFramePreferenceKey` and `gridIndex` used inside both grids must be in the shared `Components/` location before `PhotoGridView` can import them without a circular dependency on `AlbumPickerSheet.swift`), W3 (`GridImageCache` also moves to `Components/` in W3; `PhotoGridView` should import it from there)

---

### W3 — `GridImageCache` defined in `RecentsView.swift`, consumed by `AlbumGridView` [ORIGIN: architecture.md F9, SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/RecentsView.swift:16–45
- **Status:** still-present
- **What:** `GridImageCache` is a `@MainActor final class` defined at the top of `RecentsView.swift`. `AlbumGridView` declares `@State private var imageCache = GridImageCache()` (AlbumsView.swift:132), instantiating a type whose only definition is inside an unrelated view file. The `NSCache` sizing constants (600 items, 80 MB) and the `@MainActor` annotation are invisible at the point of use in `AlbumsView.swift`.
- **Failure scenario:** A developer adding a third grid consumer creates a new `GridImageCache` in their own file, duplicating the cache sizing constants independently. When memory limits are later tuned for low-RAM devices, only one copy gets the update. A developer profiling cache behavior in `AlbumGridView` must search the codebase to find that the eviction policy is defined in `RecentsView.swift`.
- **Fix direction:** Move `GridImageCache` into a new `SwipeSort/Features/Components/GridImageCache.swift` file. `RecentsView.swift` and `AlbumsView.swift` both import it from that location without code changes. This is a pure file move — no logic changes.
- **Depends on:** W1 (both W1 and W3 contribute to the same new `Components/` directory; land together to avoid a one-symbol directory)

---

### W4 — `SwipePresentationContext` defined in `RecentsView.swift`, consumed by `AlbumGridView` [ORIGIN: architecture.md F14 (rerouted from Phase 2 working set as low-severity), SEVERITY: low]
- **File:** SwipeSort/Features/Landing/RecentsView.swift:50–54
- **Status:** still-present
- **What:** `SwipePresentationContext` (the `Identifiable` struct driving `fullScreenCover(item:)` in both grids) is defined in `RecentsView.swift` and consumed by `AlbumGridView` in `AlbumsView.swift`. Same discoverability and cross-file ownership problem as W3.
- **Failure scenario:** A developer adding a third grid consumer who searches for `SwipePresentationContext` by filename finds nothing; a global symbol search is required. If the struct needs a field added (e.g. `sourceAlbumId` for filtering context after the session closes), the change must be made in a file named after an unrelated view.
- **Fix direction:** Move `SwipePresentationContext` into `SwipeSort/Features/Components/SwipePresentationContext.swift`. No callers need logic changes — it is a pure file move. May be bundled with W3 (same extraction commit, same `Components/` group).
- **Depends on:** W1, W3 (same Components/ group creation)

---

### W5 — `Features/Landing/` mixes screen-entry files with shared grid infrastructure [ORIGIN: architecture.md F10, SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/ (directory)
- **Status:** still-present
- **What:** `Features/Landing/` contains screen-entry views (`RecentsView.swift`, `AlbumsView.swift`, `BulkDeleteView.swift`, `FilterSheet.swift`, `AlbumFilterSheet.swift`, `AlbumPickerSheet.swift`) alongside types consumed across multiple screens — `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex`, `GridImageCache`, `ThumbnailCell`, `SwipePresentationContext`. The folder name gives no indication that shared grid infrastructure lives inside it.
- **Failure scenario:** As the app grows, this folder will accumulate an ad-hoc mix of screen-specific and cross-cutting code with no structural boundary. A code reviewer or new contributor reading the file map has no way to distinguish "this file is a screen" from "this file is a shared component" without reading each file.
- **Fix direction:** Create `SwipeSort/Features/Components/` and move there: the types extracted in W1 (`GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex`), W3 (`GridImageCache`), W4 (`SwipePresentationContext`), and `ThumbnailCell` (currently in `RecentsView.swift` at line 272). `Features/Landing/` then contains only screen files. `ThumbnailCell` should be its own file `Components/ThumbnailCell.swift` since it is consumed by `PhotoGridView` (W2) and has no reason to live in a view-specific file.
- **Depends on:** W1, W2, W3, W4 (all extractions land in the same `Components/` group; this item formalizes the structural outcome)

---

### W6 — `PhotoLibraryProviding` is a monolithic 22-method protocol; read-only views depend on the full mutation surface [ORIGIN: architecture.md F3, SEVERITY: high]
- **File:** SwipeSort/Core/PhotoLibraryProviding.swift:71–182
- **Status:** still-present
- **What:** The 22-method protocol bundles authorization, read-only fetch, thumbnails, mutations (`commitDeletions`, `moveAssets`, `removeAssetsFromAlbum`, `setFavorite`), caching (`startCachingThumbnails`, `stopCachingThumbnails`, `stopCachingAllThumbnails`), live-photo/video (`avPlayerItem`, `livePhoto`), filter/scoping (`applyFilter`, `scoped`), and `refreshFetchResult` into a single conformance. `RecentsView` and `AlbumGridView` declare `PhotoLibraryProviding` but only ever call: `refreshFetchResult`, `applyFilter`, `identifiers(in:)`, `assetCount`, `moveAssets`, `userAlbums`, `scoped`, `thumbnail`, `mediaKind`, `currentAuthorization`, `requestAuthorization`. `BulkDeleteView` only calls `applyFilter`, `assetCount`, `identifiers(in:)`, `commitDeletions`. Neither can accidentally call `setFavorite` or `livePhoto` today — but the type system does not prevent it, and `MockPhotoLibrary` must implement all 22 methods for any test that only needs 3. Phase 2 made both `PhotoKitLibrary` and `MockPhotoLibrary` `@MainActor`-isolated at the class level; this does not change the protocol-splitting analysis — all three sub-protocols would be `@MainActor` on their concrete implementations, same as today.
- **Failure scenario:** Adding a new mutating method (e.g. v0.7 "reset reviewed markers") forces simultaneous updates to `MockPhotoLibrary`, `AlbumsView`, `RecentsView`, and `BulkDeleteView` even though those views will never call the new method. The compiler cannot flag `AlbumGridView` accidentally calling `commitDeletions` because `PhotoLibraryProviding` permits it. Each new method added to the protocol also requires a stub in every existing mock, increasing test friction over time.
- **Fix direction:** Split into three composable protocols: `PhotoLibraryReadProviding` (authorization, fetch cursor, asset count, identifiers, thumbnails, media kind, user albums, scoped, refreshFetchResult, applyFilter), `PhotoLibraryCacheProviding` (startCachingThumbnails, stopCachingThumbnails, stopCachingAllThumbnails, avPlayerItem, livePhoto), and `PhotoLibraryMutating` (commitDeletions, createUserAlbum, moveAssets, removeAssetsFromAlbum, setFavorite). `PhotoLibraryProviding` becomes a `typealias` for `PhotoLibraryReadProviding & PhotoLibraryCacheProviding & PhotoLibraryMutating` so all existing `let library: PhotoLibraryProviding` declarations remain valid. Grid views (`RecentsView`, `AlbumGridView`) narrow their `let library` type to `PhotoLibraryReadProviding`. `BulkDeleteView` uses `PhotoLibraryReadProviding & PhotoLibraryMutating`. `SwipeSessionModel` uses the full `PhotoLibraryProviding` typealias. `WindowedThumbnailCache` narrows to `PhotoLibraryCacheProviding`. `MockPhotoLibrary` continues to conform to `PhotoLibraryProviding` so all existing tests compile; a `MockReadLibrary` stub can be introduced later for tests that only need the read surface.
- **Depends on:** none (protocol splitting does not require W1–W5 to land first; can proceed in parallel)

---

### W7 — `AppSettings.dryRunMode` exposes a developer kill-switch as a user-facing Settings toggle [ORIGIN: architecture.md F4, SEVERITY: high]
- **File:** SwipeSort/Core/AppSettings.swift:72–74; SwipeSort/Features/Settings/SettingsView.swift:54–63
- **Status:** still-present
- **What:** `AppSettings.dryRunMode` (line 72) is wired to a `Toggle("Dry-run mode (Safe simulation)", isOn: $s.dryRunMode)` in `SettingsView` under a "Safety" section (lines 54–63) visible to all users. The locked design decision in `docs/superpowers/plans/README.md` states the control must be a **hidden debug menu** accessible via long-press on the swipe-screen title bar, explicitly separate from user preferences. The current placement contradicts the locked spec and places a potentially destructive toggle (disabling it arms real PhotoKit mutations) next to appearance and gesture preferences with no friction beyond the red footer text.
- **Failure scenario:** A user who taps Settings and toggles "Dry-run mode" off does not understand they are arming real deletion. The "Safety" section header and red footer text are the only safeguard. A user who reads the label as "Safe simulation = on, nothing will happen" may interpret turning it off as harmless — then every subsequent swipe-delete permanently removes photos from their library. The locked spec's hidden-menu requirement exists precisely to prevent accidental disarming by non-developer users.
- **Fix direction:** Remove `dryRunMode` from `AppSettings` entirely. Introduce a `DeveloperSettings` singleton (or extend `DryRunMode` with a method for toggling) that is accessible only from a `LongPressGesture` on the swipe-screen title bar (the locked design spec). `SettingsView` drops the "Safety" section entirely. `DryRunMode.isEnabled` remains the single read path for all PhotoKit mutation gates in `PhotoKitLibrary` and `SwipeSessionModel`. The `AppSettings` `Key` enum drops `dryRunMode`; the `AppSettings.init` no longer reads it. Any UserDefaults migration (preserving the existing value for users who explicitly set it) should be handled in the new `DeveloperSettings` or `DryRunMode` initializer.
- **Depends on:** none (self-contained; does not require grid extraction to land first)

---

### W8 — `AlbumGridView.getScopedLibrary()` mutates `@State` inside a computed `get` body [ORIGIN: architecture.md F13 + Phase 2 reroute correctness F14, SEVERITY: low]
- **File:** SwipeSort/Features/Landing/AlbumsView.swift:317–324
- **Status:** still-present
- **What:** `getScopedLibrary()` (line 317) lazily initialises `@State private var scopedLibrary: PhotoLibraryProviding?` by assigning to `scopedLibrary` inside the function body on first call. This is a side-effect inside what reads like a pure `get`. The Phase 1 W6 fix (removing `PhotoKitLibrary.init()` observer registration) resolved the original double-registration hazard flagged in correctness F14, but the underlying pattern — creating a `PhotoKitLibrary` on a `body` render pass via a guard-and-mutate pattern — is still unusual and confusing. The `@State` lifetime guarantee holds (SwiftUI preserves `@State` across re-renders for the same view identity), but the imperative mutation inside `getScopedLibrary()` is invisible to SwiftUI's tracking machinery; `@Observable` will not notice the assignment because `getScopedLibrary()` is not marked `mutating` (it mutates `@State` indirectly through the property wrapper, which is outside the `@Observable` scope).
- **Failure scenario:** A developer refactoring `AlbumGridView` into a non-struct context (e.g. extracting into an `@Observable` model) or calling `getScopedLibrary()` in a non-`body` context (e.g. a test) would find that the pattern fails: the `@State` wrapper is not available outside of a `View.body` evaluation path. Additionally, if `AlbumGridView` is popped and re-pushed with the same `album` identity, SwiftUI may or may not preserve the `@State`; on re-creation, `getScopedLibrary()` constructs a new `PhotoKitLibrary` instance and silently discards the previous `PHFetchResult` cursor, forcing an unnecessary full re-fetch.
- **Fix direction:** Replace `getScopedLibrary()` with a `.task(id: album.id)`-driven initialisation: add `@State private var scopedLibrary: PhotoLibraryProviding?` and inside `.task(id: album.id)` set `scopedLibrary = library.scoped(toAlbumId: album.id)` if `scopedLibrary == nil || scopedLibrary is a different album`. `body` reads `scopedLibrary ?? library` as a fallback (safe since `loadAssets` only runs after `.task` fires). Alternatively, initialise with `let scopedLibrary = library.scoped(toAlbumId: album.id)` as a stored property if `AlbumGridView` is refactored per W2 (since `PhotoGridView` would receive the scoped library already resolved by `AlbumGridView`'s init). The W2 extraction naturally resolves this by moving the scoped-library creation into the new composite view's init or `.task`.
- **Depends on:** W2 (the W2 refactor may naturally resolve this by moving `getScopedLibrary()` into `PhotoGridView`'s init path)

---

## Already fixed (dropped from Phase 3)

*(none — no in-scope architecture findings were resolved by Phase 1 or Phase 2)*

---

## Rerouted to other phases

- **architecture.md F6 — `SwipeStackView` (686 lines post Phase 1+2) lacks file-level seam extraction** — moved to Phase 7; reason: Phase 3 scope is architectural duplication and misplaced primitives. `SwipeStackView` has no duplication with another file; its `// MARK: -` section separators already exist (Header, Card Area, Peeking, Drag Hint Overlay, Album Grid, Control Bar, Static States, Gesture). The file grew from 649 to 686 lines with Phase 1 fixes (6 seam findings + R2 fix bundle). The remaining concern is file-size/naming cleanup, which aligns with Phase 7's explicit scope ("cleanup, naming, dead code").

- **architecture.md F7 — `PhotoKitLibrary` (528 lines post Phase 1+2) has no complete `MARK:` grouping** — moved to Phase 7; reason: Phase 1+2 added the `// MARK: - Private helpers` and `// MARK: - Albums` separators, but `Authorization`, `Fetch cursor`, `Thumbnails & caching`, `Mutations`, and `Video & Live Photo` sections are still missing. This is a readability/discoverability-only fix with zero compilation impact, matching Phase 7's "cleanup" scope. No duplication or misplaced-primitive concern.

- **architecture.md F8 — `SwipeSessionModel` conflates four distinct responsibilities** — moved to Phase 7; reason: Phase 1 added a `// MARK: - Private` separator and the file grew to 441 lines with all decision-lifecycle fixes. The structural concern (mixing session lifecycle, decision recording, thumbnail loading, and undo navigation) remains, but the Phase 3 scope explicitly covers "shared grid extraction + architecture cleanup" for items with duplication or misplaced-primitive character. `SwipeSessionModel` has no duplication with another file; the `MARK:` and optional `ThumbnailPreloader` extraction is a single-file cleanup matching Phase 7.

- **architecture.md F11 — `swipeKeep` dead alias for `swipeFavorite`** — moved to Phase 7; reason: Phase 1 W7 fix correctly decoupled `swipeKeep()` from `swipeFavorite()` — `swipeKeep()` now calls only `queue.record(.keep)` and `advance()`, with no `setFavorite` side-effect. However, `swipeKeep()` is still never called by any gesture path (all gesture routing in `SwipeSessionModel.swipe(_:using:)` calls `swipeFavorite()` directly for the "down/left = keep" direction). The function is therefore a dead alias for "advance + record keep without favoriting," which is semantically distinct from swipeFavorite but unreachable from the UI. This is a naming/dead-code concern for Phase 7, not an architectural duplication for Phase 3.

- **architecture.md F12 — `DeletionQueueView` declared in `ReviewCommitView.swift`** — moved to Phase 7; reason: file-naming confusion with no runtime impact. Phase 7's scope explicitly includes "cleanup, naming, dead code."

- **correctness.md F11 — `BulkDeleteView.applyFilter` mutates shared library state** (rerouted from Phase 2) — partially addressed by Phase 2 W1: `PhotoKitLibrary` is now `@MainActor`-isolated, so concurrent races on `activeFilter` are eliminated. The residual architectural concern — `BulkDeleteView` and `RecentsView` sharing a single `PhotoLibraryProviding` instance so that `BulkDeleteView`'s `applyFilter` call mutates the shared fetch cursor seen by `RecentsView` — is a shared-ownership design issue. However, this is resolved by W6 (narrowing `BulkDeleteView`'s dependency to `PhotoLibraryReadProviding & PhotoLibraryMutating`) plus a scoped library for bulk operations. Including here as an implementation note for W6: `BulkDeleteView` should receive a `scoped` or `refreshed` library instance to avoid clobbering the parent view's cursor.

---

## New architecture issues surfaced by re-verify

### N1 — `SwipeSessionModel.start()` directly references the `PhotoLibraryChangePublisher.shared` singleton [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:89
- **What:** Phase 1 W6 correctly moved `PhotoLibraryChangePublisher.shared.register()` from `PhotoKitLibrary.init()` into `SwipeSessionModel.start()` (post-authorization). However, `SwipeSessionModel` now holds a hard-coded dependency on the `PhotoLibraryChangePublisher.shared` singleton. This makes it impossible to inject a test-double observer in unit tests, and couples the session model to the global notification bus without any protocol abstraction.
- **Failure scenario:** A test for `SwipeSessionModel.start()` authorization-branch behavior cannot verify that `register()` was called (or not called on denial) without either swizzling `PhotoLibraryChangePublisher.shared` or running on a real device with a real `PHPhotoLibrary`. If a future multi-session scenario is introduced (e.g., two simultaneous sessions), both sessions would call `shared.register()` and both would receive all change notifications, with no way to scope notifications to a specific session.
- **Fix direction:** The Phase 3 fix is low-effort: since `PhotoLibraryChangePublisher.register()` is already annotated `@MainActor` (Phase 2 N1 fix), add a `var changePublisher: PhotoLibraryChangePublisher = .shared` property to `SwipeSessionModel` (or inject it via init with a default of `.shared`) so tests can substitute a mock. This is a small injection point, not a full protocol; a `@MainActor protocol LibraryChangeRegistering { func register() }` conformance on `PhotoLibraryChangePublisher` would make it fully testable. Severity is low because the singleton reference is correctly placed (post-authorization) and the idempotency guard prevents double-registration.

### N2 — `MainTabView` creates `PhotoLibraryProviding` via `@State` and threads it by init, inconsistent with `AppSettings`'s `@Environment` injection [ORIGIN: architecture.md F5, SEVERITY: medium]
- **File:** SwipeSort/Features/MainTabView.swift:10–26
- **What:** `MainTabView` creates the shared library as `@State private var library: PhotoLibraryProviding` and passes it to `RecentsView(library:)` and `AlbumsView(library:)` through init parameters. `AppSettings` is injected via `.environment(settings)` from `SwipeSortApp` and consumed via `@Environment(AppSettings.self)` everywhere. The library uses a different injection pattern — init threading — meaning `SettingsView` has no access path to the library, and any view deeper than one navigation level must receive it through the init chain. This was noted as F5 in `architecture.md` (pending-verify status) and is confirmed present.
- **Failure scenario:** When v0.7 adds settings that call a library method (e.g., "reset reviewed markers" from `SettingsView`), `SettingsView` must either receive the library through `MainTabView`'s init (requiring changes to three files: `SwipeSortApp`, `MainTabView`, `SettingsView`) or obtain it from `@Environment` — but no environment key for the library exists. The inconsistency will surprise future contributors who see `@Environment(AppSettings.self)` working in `SettingsView` but find no `@Environment` path to the library.
- **Fix direction:** Define an `EnvironmentKey` for `PhotoLibraryProviding` (e.g., `\.photoLibrary`) with a no-op default. In `SwipeSortApp` (or `MainTabView`), inject the library into the environment with `.environment(\.photoLibrary, library)`. All child views switch from `let library: PhotoLibraryProviding` init params to `@Environment(\.photoLibrary) private var library`. The `#if DEBUG` mock-switching logic stays in `MainTabView.init()` as today. This is a medium-effort refactor touching `MainTabView`, `RecentsView`, `AlbumsView`, `BulkDeleteView`, `AlbumGridView`, and `AlbumPickerSheet`, but each change is mechanical (replace init param with `@Environment` read).

### N3 — `BulkDeleteView` mutates the shared `PhotoLibraryProviding` cursor, potentially corrupting `RecentsView`'s active fetch state [ORIGIN: correctness.md F11, rerouted from Phase 2, SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/BulkDeleteView.swift:104–108
- **What:** `BulkDeleteView` receives the same `PhotoLibraryProviding` instance as `RecentsView` (both come from `MainTabView.library`). Its `.task(id: filter)` calls `library.applyFilter(filter)` on this shared instance, which sets `activeFilter` and nullifies `fetchResult` on the shared `PhotoKitLibrary`. If `BulkDeleteView` is presented as a sheet while `RecentsView` is still loaded, the next time `RecentsView` calls `loadAssets()` (e.g. on `PhotoLibraryChangePublisher.didChangeNotification`) its `applyFilter` call will use whatever filter `BulkDeleteView` last applied, or if `BulkDeleteView`'s filter differs, `RecentsView`'s previously cached `PHFetchResult` has been invalidated. Phase 2 W1 eliminated the concurrency race on `activeFilter`, but the shared-mutation contract is still architecturally unsafe.
- **Failure scenario:** User opens `BulkDeleteView`, selects "Videos only" filter, then dismisses without deleting. `RecentsView.loadAssets()` fires (triggered by a library change notification). Because `BulkDeleteView` left `activeFilter = .videosOnly` on the shared library, `RecentsView` now shows only videos even though the user set their Recents filter to `.unfiltered`. The user's Recents filter state (`@State private var filter: SwipeFilter`) is now stale versus the library's active cursor.
- **Fix direction:** `BulkDeleteView` should operate on a fresh scoped or independently-filtered library instance rather than the shared one. The cleanest fix is to have `BulkDeleteView` call `library.scoped(toAlbumId: nil)` or create a dedicated `PhotoKitLibrary()` instance in `BulkDeleteView.init` (or via a `withFilteredLibrary` helper). This naturally resolves the W6-noted implementation note. Alternatively, narrowing `BulkDeleteView.library` to a protocol that does not include `applyFilter` (e.g. a version of `PhotoLibraryReadProviding` plus `commitDeletions`) would make the shared-mutation hazard a compile error. This item is closely related to W6 and should be coordinated with it.
- **Depends on:** W6 (protocol split makes the correct dependency surface explicit; a `BulkDeleteView`-specific sub-protocol would make the hazard visible to the compiler)

---

## Recommended fix order

1. **W7 — Remove `dryRunMode` from `AppSettings` + implement hidden debug menu** — Self-contained; no grid work required; resolves a locked-spec violation that carries user-safety implications. Land first.

2. **W1 + W3 + W4 (bundle)** — Create `Features/Components/` and extract `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex`, `GridImageCache`, and `SwipePresentationContext` in one commit. These are pure file moves with no logic changes; they establish the `Components/` directory that W2 and W5 depend on.

3. **W6 — Split `PhotoLibraryProviding` into sub-protocols** — Independent of all grid extraction work. Can proceed in parallel with the W1/W3/W4 bundle if desired, or land immediately after W7 as a second self-contained change. Narrowing view dependencies makes W2 cleaner (the extracted `PhotoGridView` declares `PhotoLibraryReadProviding`, not the full protocol).

4. **N3 — Fix `BulkDeleteView` shared-library mutation** — Coordinate with W6 (W6 defines the sub-protocol that makes N3's correct narrowing expressible). Land after W6.

5. **W2 — Extract `PhotoGridView`** — Depends on W1/W3/W4 (`Components/` group exists) and W6 (sub-protocol type for `PhotoGridView.library`). The largest change in the phase; land after the foundations are in place.

6. **W5 — Move `ThumbnailCell` to `Components/`** — Depends on W2 (once `PhotoGridView` exists, `ThumbnailCell` is cleanly a component used only by `PhotoGridView`). Land after W2.

7. **W8 — Fix `AlbumGridView.getScopedLibrary()` init pattern** — Likely resolved naturally by W2 (the scoped-library creation moves into `AlbumGridView`'s setup for `PhotoGridView`). Verify after W2 lands; if residual, land as a follow-up.

8. **N1 — Inject `PhotoLibraryChangePublisher` into `SwipeSessionModel`** — Low severity; independent of all grid work. Can land at any point, or be deferred to Phase 5 as a testability improvement (the testing lens already flags `SwipeSessionModel.start()` coverage gaps).

9. **N2 — Convert `library` injection from init-threading to `@Environment`** — Medium effort; mechanical but touches many files. Land after W2 (which refactors the init signature of the grid views) to avoid double-touching `RecentsView` and `AlbumsView`. Can be deferred to Phase 7 if Phase 3's scope is already large.

Independence note: W7, W6+N3, and the W1/W3/W4 bundle are fully independent of each other and can proceed in parallel if desired. W2 and W5 form a sequential chain that depends on both the `Components/` group (W1/W3/W4) and the narrowed protocol (W6).

---

## Testing follow-ups (Phase 5 input)

- Verify that `RecentsView` compiles and renders correctly after the `PhotoLibraryProviding` → `PhotoLibraryReadProviding` narrowing (W6 regression: no accidental call to a mutating method in the grid view body).
- Verify that `MockPhotoLibrary` still satisfies `PhotoLibraryProviding` (now a typealias) after the split; confirm all existing `SwipeDecisionQueueTests` and `SwipeSessionModelTests` still compile (W6 regression).
- Test that `BulkDeleteView`'s filter application does not affect `RecentsView`'s `loadAssets` output after N3 fix — construct two views sharing a library, trigger `BulkDeleteView.applyFilter(.videosOnly)`, then call `RecentsView.loadAssets()` and assert the returned identifiers match `.unfiltered` semantics (N3 regression).
- Verify that the hidden debug menu long-press gesture on the swipe-screen title correctly reads and writes `DryRunMode.isEnabled` after W7 — drive the gesture in a UI test and assert the `DryRunMode.isEnabled` value toggles without any `SettingsView` interaction (W7 regression).
- Test `SwipeSessionModel.start()` with a mock `changePublisher` after N1 — verify `register()` is called on `.authorized` and not called on `.denied`, without requiring a real `PHPhotoLibrary` instance (N1 testability improvement).
- Verify that `AlbumGridView` constructs only one `PhotoKitLibrary` instance across multiple `body` re-evaluations after W8 fix — assert `PHCachingImageManager` is not re-initialised on each render pass by counting `scoped(toAlbumId:)` invocations via `MockPhotoLibrary.scopedCallCount` (W8 regression).
- Verify that the `PhotoGridView` extraction (W2) produces accessibility identifiers `"ThumbnailCell-\(index)"` on every cell in both the Recents and Albums grids — an XCUITest that queries `app.images.matching(identifier: "ThumbnailCell-0")` should find the element in both tabs (W2 one-sided-fix regression).
