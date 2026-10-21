# Naming, Dead Code, Redundancy
**Reviewer:** cleanup-lens  **Date:** 2026-07-13  **Verify status:** pass

## Summary
The codebase is generally clean, but carries a handful of naming problems that have grown stale since the rename from "keep" to "favorite" semantics: `swipeKeep` is a dead-weight alias whose existence forces readers to ask which name is authoritative, and the `GestureMode` enum doc-comments still say "Keep" while every user-facing string says "Fav." `totalPendingCount` is a pure synonym for `pendingDeletions.count` and adds cognitive load without value. `SwipeFilter.MediaTypeFilter.livePhotosOnly` is an unreachable enum case—the setter ignores it and `nsPredicate` never emits a predicate for it, so filtering for Live Photos silently returns all photos. The grid infrastructure (`ThumbnailCell`, `GridImageCache`, `GridCellFramePreferenceKey`, `gridIndex`, `GridSelectionBottomBar`) is physically split across `RecentsView.swift` and `AlbumPickerSheet.swift` while being logically shared, creating a housing mismatch. The `finishedSummary` in `SwipeStackView` duplicates an entire "Go Back" `Button` body to change only `.buttonStyle`. Several doc-comments reference unimplemented `v0.3+` infrastructure (`ReviewedAssetStore`) or persist `v0.1` skeleton claims long after the features landed. The caching protocol surface has three methods where two would suffice, and `shouldAutoplay`'s body ignores its `durationSeconds` parameter entirely.

## Findings

### F1 — `swipeKeep` is a dead alias for `swipeFavorite` [SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:77-79
- **What:** `swipeKeep()` is a public method whose only body is `await swipeFavorite()`, making it a permanent synonym with no semantic distinction; every production call path (gesture dispatch) goes through `swipeFavorite` directly, and `swipeKeep` is only called from tests.
- **Why it matters / failure scenario:** A future developer reads the public API and cannot determine which name is canonical. Tests written against `swipeKeep` give false confidence that both symbols are tested independently when they are not. If the semantics of "keep" and "favorite" ever diverge (keep = skip-with-no-flag, favorite = set Photos flag), this silent alias will apply the favorite flag when only keep was intended—corrupting the library silently.
- **Suggested fix direction:** Decide on one canonical name. Given that the operation sets the Photos favorite flag and records a `.keep` decision, `swipeFavorite` is the more accurate name. Remove `swipeKeep`, update the handful of test call sites to use `swipeFavorite`, and update any `SwipeDecision.keep` usages to reflect the correct semantic label.
- **Verified:** plausible — call sites confirmed: `swipeKeep` is called only from test files (SwipeSessionModelTests, AlbumMoveTests, CommitDeletionsTests). No production caller invokes it. Factual claim is substantiated; the "dead alias" label is a judgment call. Kept at high.

### F2 — `GestureMode` doc-comments say "Keep" but every user-facing string says "Fav" [SEVERITY: high]
- **File:** SwipeSort/Core/AppSettings.swift:11-13, SwipeSort/Features/Settings/SettingsView.swift:85-86
- **What:** The `GestureMode` enum doc-comment for `upDeleteDownKeep` reads "Down = Keep" and for `rightDeleteLeftKeep` reads "Left = Keep," yet `swipeFavorite` (which sets the Photos favorite flag) is what those directions trigger, and the UI labels in `SettingsView.displayName` correctly say "Fav."
- **Why it matters / failure scenario:** The mismatch means the source-of-truth for the gesture definition (the enum in `AppSettings.swift`) tells a different story from the runtime behavior. A developer reading the enum thinks "keep" = skip-and-log, but the actual call is `swipeFavorite` = set-favorite-flag + advance; this is the same root confusion as F1 and could cause a mis-implementation if the gesture dispatch is ever refactored.
- **Suggested fix direction:** Update the enum doc-comments to match the actual behavior: "Down = Favorite (sets Photos favorite flag)" and "Left = Favorite." After resolving F1, keep a single consistent term everywhere.
- **Verified:** yes (adversarial subagent confirmed — AppSettings.swift:11,14 docs say "Keep"; SettingsView.swift:85-86 displayName says "Fav"; runtime calls `swipeFavorite()`)

### F3 — `SwipeFilter.MediaTypeFilter.livePhotosOnly` is an unreachable dead case [SEVERITY: high]
- **File:** SwipeSort/Core/SwipeFilter.swift:18, 67
- **What:** The `MediaTypeFilter` enum has a `livePhotosOnly` case, but the `mediaType` setter treats it identically to `.any` (clears all selection without inserting a type), and `nsPredicate()` never generates a predicate for it, so selecting "live photos only" silently returns every asset.
- **Why it matters / failure scenario:** Any code that constructs or pattern-matches on `.livePhotosOnly` operates under a false assumption that live-photo filtering is active. A user who builds a `SwipeFilter` with `.mediaType = .livePhotosOnly` will swipe through their entire library instead of only live photos, with no error or warning.
- **Suggested fix direction:** Either implement the Live Photos predicate using `PHAssetMediaSubtype.photoLive` (analogous to the `.screenshots` branch), or remove `livePhotosOnly` from the enum until it is implemented. Also remove the silent fallthrough in the setter.
- **Verified:** yes (adversarial subagent confirmed — case defined at line 18, setter groups it with `.any` in a no-op break at line 67, getter never emits `.livePhotosOnly`, `nsPredicate` never generates a predicate for it. Grep confirms no other file references the case)

### F4 — `totalPendingCount` is a pure synonym for `pendingDeletions.count` [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:209-211
- **What:** `totalPendingCount` is a computed property defined as `pendingDeletions.count`—it adds no additional semantics, no caching, and no derivation; it is a transparent rename of an already-public property.
- **Why it matters / failure scenario:** Having two names for the same value fragments call sites: `SwipeStackView` uses `model.totalPendingCount` on line 231 while the rest of the file uses `model.pendingDeletions.count` directly (lines 163, 471, 472, 500). Callers cannot tell whether the two return the same value without tracing both, and any future divergence (e.g., "pending" starts including moves) would be invisible until both properties are updated.
- **Suggested fix direction:** Remove `totalPendingCount`. Replace the single call site in `SwipeStackView` (line 231) with `model.pendingDeletions.count` to match all other call sites.
- **Verified:** pending

### F5 — `DecisionQueue.deleteCount` is unused by all production callers [SEVERITY: medium]
- **File:** SwipeSort/Core/SwipeDecision.swift:33-38
- **What:** `DecisionQueue.deleteCount` is a public computed property that counts `.delete` decisions in the queue, but no production code reads it—`SwipeSessionModel` exposes `pendingDeletions` (a deduped list) and `SwipeStackView` calls `model.pendingDeletions.count` directly. `deleteCount` is only read in unit tests.
- **Why it matters / failure scenario:** The property introduces a second way to count deletes alongside `pendingDeletions.count`. Crucially, they can disagree: `pendingDeletions` deduplicates by asset identifier (a user can swipe-delete the same asset twice via undo-redo), but `deleteCount` counts raw decision entries. A caller using `deleteCount` instead of `pendingDeletions.count` would display a higher number than the actual commit batch, misleading the user.
- **Suggested fix direction:** If deduplication is the correct semantics, remove `deleteCount` and write tests against `pendingDeletions.count` (or expose `pendingDeletions.count` directly on the queue). If raw count is intentionally different, document the distinction and add a test that exercises the duplicate case.
- **Verified:** pending

### F6 — Stale doc-comment on `SwipeSessionModel` references unimplemented `ReviewedAssetStore` [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:7-12
- **What:** The class doc-comment describes four behaviors that are conditional on a `ReviewedAssetStore` being provided (v0.3+), but no such type exists anywhere in the codebase and the initializer has no parameter for it; the behaviors (skipping reviewed indices, persisting decisions, rollback on undo) are not implemented.
- **Why it matters / failure scenario:** Any developer reading the doc-comment will assume these v0.3+ behaviors are active and may rely on them for correctness reasoning (e.g., "undo rolls back the persisted marker"). Because they don't exist, session-resume, decision persistence, and skip-reviewed logic are silently absent with no indication to callers.
- **Suggested fix direction:** Remove the conditional block of the doc-comment or mark it explicitly as `// TODO(v0.3):` so it is clearly aspirational, not descriptive. Add a test or a compile-time assertion if the feature is genuinely upcoming.
- **Verified:** pending

### F7 — `DecisionQueue` doc-comment claims v0.1-only persistence is still pending but v0.3 never landed [SEVERITY: medium]
- **File:** SwipeSort/Core/SwipeDecision.swift:26-27
- **What:** The comment reads "In v0.1 the queue lives only for the lifetime of the app process — persistence arrives in v0.3," implying persistence is a future v0.3 feature. No persistence exists in the current codebase and v0.3 has shipped by the file-map date, making this a stale forward-reference that now incorrectly implies persistence should be present.
- **Why it matters / failure scenario:** A developer tasked with debugging "decisions lost after app restart" will first look at this comment and assume persistence is already implemented somewhere, wasting investigation time before concluding it was never built.
- **Suggested fix direction:** Remove the "persistence arrives in v0.3" claim. Replace with either a TODO noting that persistence is deferred, or remove the versioned note entirely and let the code speak for itself.
- **Verified:** pending

### F8 — `PhotoKitLibrary` doc-comment says caching window is v0.1 but `WindowedThumbnailCache` already exists [SEVERITY: medium]
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:13-14
- **What:** The design note reads "Callers do not manage the caching window themselves in v0.1; we just request thumbnails as swipes happen. Windowed pre-caching arrives in v0.5." The codebase already contains `WindowedThumbnailCache` (a full sliding-window implementation), so the comment describes an obsolete state.
- **Why it matters / failure scenario:** A reader will think the current code uses on-demand fetching rather than pre-caching, and may introduce unnecessary manual thumbnail requests or fail to rely on the cache warm-up logic already in place.
- **Suggested fix direction:** Replace the note with a description of the current architecture: windowed pre-caching is implemented via `WindowedThumbnailCache` held by `SwipeStackView`; `PhotoKitLibrary` exposes the three caching primitives that the cache drives.
- **Verified:** pending

### F9 — `GridImageCache`, `ThumbnailCell`, and shared grid helpers live in the wrong files [SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/RecentsView.swift:13-40, 267-352; SwipeSort/Features/Landing/AlbumPickerSheet.swift:151-199
- **What:** `GridImageCache` and `ThumbnailCell` are defined in `RecentsView.swift` but are also used by `AlbumGridView` (in `AlbumsView.swift`). The shared infrastructure (`GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex`) lives in `AlbumPickerSheet.swift`, which is semantically unrelated to grid selection.
- **Why it matters / failure scenario:** A developer adding a third grid view must know to look in two separate files for the shared components. If `RecentsView.swift` is renamed or moved, `AlbumGridView` breaks at compile time because `ThumbnailCell` and `GridImageCache` move with it. The mismatch between file name (`AlbumPickerSheet.swift`) and contents (grid preference key and selection bar) makes the codebase harder to navigate.
- **Suggested fix direction:** Extract `GridImageCache`, `ThumbnailCell`, `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, and `gridIndex` into a dedicated `GridComponents.swift` (or similar) file under `Features/Landing/`. Both `RecentsView` and `AlbumGridView` then import from a single authoritative source.
- **Verified:** pending

### F10 — Duplicated grid body (LazyVGrid + drag gesture + selection tap) between `RecentsView` and `AlbumGridView` [SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/RecentsView.swift:104-165; SwipeSort/Features/Landing/AlbumsView.swift:165-226
- **What:** The `ScrollView { LazyVGrid { ForEach … ThumbnailCell … } }` block, the `GeometryReader`/`GridCellFramePreferenceKey` background, the tap-gesture (select vs open), and the entire `DragGesture` (minimumDistance, `onChanged` range-select, `onEnded` reset) are copied verbatim between `RecentsView` (lines 104-165) and `AlbumGridView` (lines 165-226), with only minor string literals differing.
- **Why it matters / failure scenario:** Any bug fix or UX change to the gesture logic must be applied in two places. The `ThumbnailCell-\(index)` accessibility identifier exists only in `RecentsView` (line 123) and is missing from `AlbumGridView` (line 184), already showing divergence; UI tests that navigate into an album grid will not find cells by that identifier.
- **Suggested fix direction:** Extract the grid body into a reusable `AssetGridView` SwiftUI view parameterized on `assetIds`, `imageCache`, `isSelecting`, `selectedIds`, `library`, and an action closure. Both `RecentsView` and `AlbumGridView` wrap this view and own their own state.
- **Verified:** pending

### F11 — `ThemeMode.displayName` extension is redundant with capitalized rawValue [SEVERITY: low]
- **File:** SwipeSort/Features/Settings/SettingsView.swift:72-80
- **What:** The private `ThemeMode.displayName` extension returns `"System"`, `"Light"`, `"Dark"` — which are exactly the `rawValue` strings (`"system"`, `"light"`, `"dark"`) with an initial capital. The extension exists solely to capitalize strings that could instead be capitalized in the enum's rawValue declaration or via `.capitalized` at the call site.
- **Why it matters / failure scenario:** If a new `ThemeMode` case is added (e.g., `highContrast`), the developer must remember to add a `displayName` branch; missing it would cause a non-exhaustive switch at compile time only for `GestureMode` (which is non-trivially named), while `ThemeMode` would silently fall through to the compiler warning. This is minor but adds unnecessary surface area.
- **Suggested fix direction:** Either change `ThemeMode` rawValues to already-capitalized strings ("System", "Light", "Dark") so `rawValue` can be used directly in the picker, or use `rawValue.capitalized` at the call site and remove the extension.
- **Verified:** pending

### F12 — `GestureMode.displayName` carries human-readable descriptions that duplicate mode semantics already in the enum doc-comments [SEVERITY: low]
- **File:** SwipeSort/Features/Settings/SettingsView.swift:82-89
- **What:** `GestureMode.displayName` encodes gesture mappings ("Up: Delete, Down: Fav") as a UI string, duplicating the intent of the enum's doc-comments in `AppSettings.swift`. Additionally (see F2), the enum doc-comment says "Keep" while `displayName` says "Fav," creating a permanent inconsistency between the two description locations.
- **Why it matters / failure scenario:** The user-visible label and the developer-facing doc-comment will continue to drift independently. Future modes added to `GestureMode` require updates in at least three places: the enum, the doc-comment, and `displayName`.
- **Suggested fix direction:** After resolving F2, consolidate the description to one location. Consider a single `localized` property or a static string table keyed off the enum, so docs and UI always read from the same source.
- **Verified:** pending

### F13 — `shouldAutoplay` ignores its `durationSeconds` parameter [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeCardView.swift:86-88
- **What:** `shouldAutoplay(durationSeconds:settings:)` accepts a `durationSeconds` parameter that is never read; the body is `return settings.autoplayVideos`.
- **Why it matters / failure scenario:** The comment above the function says "Autoplay is gated by the master toggle first, then the per-clip threshold," implying a duration threshold exists, but no threshold logic is present. Tests pass duration values (10, 30, 600 seconds) that are all treated identically, so the test suite cannot catch a regression where very long videos are incorrectly autoplayed. The parameter is dead weight that misleads callers.
- **Suggested fix direction:** Either remove the `durationSeconds` parameter (and update call sites and tests) if a per-clip threshold is not planned, or implement the threshold and add tests that exercise the boundary. The `SwipeCardView.swift` comment "v0.7 flips this to a user setting" suggests the threshold was intended; if so, add a TODO and keep the parameter but document it as not-yet-wired.
- **Verified:** pending

### F14 — `isPrev` detection logic is duplicated three times inside `SwipeStackView` [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:253-260, 574-580, 591-597
- **What:** The four-line block that computes `isPrev: Bool` by switching on `settings.gestureMode` and testing `isVertical + dx/dy sign` appears identically in `isDraggingPrev` (lines 253-260), `swipeGesture.onChanged` (lines 574-580), and `swipeGesture.onEnded` (lines 591-597).
- **Why it matters / failure scenario:** If the gesture mapping for "prev" direction changes (e.g., a third gesture mode is added), all three sites must be updated in sync. A partial update would produce inconsistent rubber-band resistance vs. snap-back behavior.
- **Suggested fix direction:** Extract a private `isPrevDirection(dx:dy:mode:) -> Bool` helper and call it from all three sites. The existing `isDraggingPrev` computed property already does this work but is not reused inside the gesture handler itself.
- **Verified:** pending

### F15 — "Go Back" button body is duplicated verbatim in `finishedSummary`; only `.buttonStyle` differs [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:519-545
- **What:** The `if model.pendingDeletions.isEmpty || commitResult != nil` branch and the `else` branch both contain the same `Button { dismiss() } label: { HStack … "Go Back" … }` body; the only difference is `.buttonStyle(.borderedProminent)` vs `.buttonStyle(.bordered)`.
- **Why it matters / failure scenario:** Any change to the button label, icon, font, or padding must be applied twice. The branches are adjacent but the duplication is non-obvious because the two copies are separated by a closing brace and a comment.
- **Suggested fix direction:** Hoist the `Button` definition once and apply `.buttonStyle` conditionally via a ternary or an `AnyButtonStyle` wrapper keyed off the condition.
- **Verified:** pending

### F16 — `queueGrid` inner `if !model.pendingDeletions.isEmpty` is always true [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/ReviewCommitView.swift:62
- **What:** `queueGrid` is only reachable when `model.pendingDeletions.isEmpty == false` (the caller at line 19 branches on this). The inner `if !model.pendingDeletions.isEmpty` guard at line 62 is therefore always true and the dead `else` branch (implicit empty `VStack`) can never render.
- **Why it matters / failure scenario:** The guard creates a false impression that `queueGrid` might display nothing, and the section header + `LazyVGrid` would be unreachable if the guard were ever updated incorrectly. It also means the `ScrollView` renders an empty `VStack` shell even in the "no deletions" case that logically can't occur here.
- **Suggested fix direction:** Remove the inner `if !model.pendingDeletions.isEmpty` wrapper. The outer branch in `body` already guarantees non-empty state.
- **Verified:** pending

### F17 — `MockPhotoLibrary.removeAssetsFromAlbum` does not record the call, unlike `moveAssets` [SEVERITY: low]
- **File:** SwipeSort/Core/MockPhotoLibrary.swift:127-129
- **What:** `removeAssetsFromAlbum` always returns `.success` and does not append to any `lastMoves`-style tracking array, whereas `moveAssets` records to `lastMoves`. Tests that exercise `undo()` of a move-from-All-Photos path (which calls `removeAssetsFromAlbum`) cannot assert on whether the remove was actually called.
- **Why it matters / failure scenario:** A regression where `undo()` skips the `removeAssetsFromAlbum` call entirely would not be caught by the mock; the test would pass even though the production behavior is broken.
- **Suggested fix direction:** Add a `lastRemovals: [(albumId: String, ids: [AssetIdentifier])]` tracking array and append to it in `removeAssetsFromAlbum`, mirroring the pattern used by `moveAssets`.
- **Verified:** pending

### F18 — `PhotoLibraryProviding` protocol comment on `PhotoLibraryProviding` still says "v0.2 adds the batch deletion commit" [SEVERITY: low]
- **File:** SwipeSort/Core/PhotoLibraryProviding.swift:49-50
- **What:** The protocol doc-comment reads "v0.2 adds the batch deletion commit," implying the current codebase is at or around v0.2. The file map notes the codebase is at v0.6+. The versioned annotation is now historical noise rather than a useful hint.
- **Why it matters / failure scenario:** Readers are given a misleading picture of the protocol's maturity and history. More importantly, the comment doesn't describe what the protocol actually is — it conflates version history with API description.
- **Suggested fix direction:** Remove the version annotation and replace with a statement about the protocol's current responsibility: abstracting all PhotoKit access to allow substitution of `MockPhotoLibrary` in tests.
- **Verified:** pending

### F19 — Three caching protocol methods where two semantics suffice [SEVERITY: low]
- **File:** SwipeSort/Core/PhotoLibraryProviding.swift:104-106
- **What:** The protocol declares `startCachingThumbnails`, `stopCachingThumbnails`, and `stopCachingAllThumbnails`. The first two are delta-caching primitives used by `WindowedThumbnailCache`; the third is a bulk nuclear reset. This is a reasonable split, but the protocol comment for `stopCachingThumbnails` warns that the `(targetSize, contentMode, options)` tuple must be byte-identical to the start call, which is an implementation contract that the protocol itself cannot enforce. This creates a fragile implicit coupling.
- **Why it matters / failure scenario:** If a second `WindowedThumbnailCache` instance were created with a different `targetSize`, calling `stopCachingAllThumbnails` would clear caches started by the other instance. This is currently fine but the protocol surface is difficult to use correctly because the pairing invariant is invisible to callers of the protocol abstraction.
- **Suggested fix direction:** Document the pairing requirement explicitly in the protocol (it is currently only in `PhotoKitLibrary.stopCachingThumbnails`'s inline comment). Consider whether `stopCachingThumbnails` and `startCachingThumbnails` should be wrapped in a `CachingSession` value type that enforces matching parameters by construction — a future refactor, but worth noting as a direction.
- **Verified:** pending

### F20 — `SwipeSessionModel.toggleFavorite` is defined but never called from any production view [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:114-117
- **What:** `toggleFavorite(_ isFavorite: Bool)` is a public method that sets the Photos favorite flag on the current asset independently of the swipe gesture. The `SwipeStackView` control bar comment (line 12) advertises a `[♥ Favorite]` button but the actual `controlBar` view (lines 399-430) only contains the `Undo` button; no production call site invokes `toggleFavorite`.
- **Why it matters / failure scenario:** The method is part of the public API of `SwipeSessionModel`, tested in isolation, but provides no runtime value to users. If the ♥ button is ever added to the control bar and a developer searches for how to call it, they will find `toggleFavorite`—but if `swipeFavorite` (which also calls `setFavorite`) was the intended path, using `toggleFavorite` would not advance the card, diverging from user expectation.
- **Suggested fix direction:** Either implement the ♥ button in `SwipeStackView` and wire it to `toggleFavorite` (which is independent of the gesture flow and does not advance), or remove `toggleFavorite` and document that favoriting only happens via the swipe gesture path (`swipeFavorite`).
- **Verified:** pending
