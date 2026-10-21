# Phase 7 Working Set — Cleanup & Naming Findings
**Date:** 2026-07-16
**Source:** cleanup.md + trailing lows from all lens docs + code-sweep of current state
**Method:** each anchor re-read in the current tree; findings classified LIVE / CLOSED / PARTIAL / SUPERSEDED.

## Summary
- 20 findings in cleanup.md; 4 tail-lows in best-practices.md; 4 in architecture.md; 2 in performance.md; 1 in correctness.md; 7 in testing.md.
- **LIVE (12):** cleanup F1, F2, F3, F4, F5, F6, F13, F14, F15, F16, F20 · best-practices F11 · testing F14, F16, F18, F19, F20 · architecture F12, F13, F14 · performance F13.
- **CLOSED by earlier phases (16):** cleanup F7, F8, F9, F10, F11, F12, F17, F18, F19 · best-practices F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F12, F13, F14, F15, F16, F17 (dup), F18 · correctness F17, F18 · performance F14 · testing F13.
- **Won't-fix (2):** performance F13 (silent-truncation cap), performance F14 (AVAsset resource-loading cancellation).

## Phase-7 gate: no `high` findings anywhere
The three `high` items in cleanup.md are F1 (`swipeKeep` alias), F2 (`GestureMode` doc-comment mismatch), F3 (`livePhotosOnly` dead case). All three are covered below and MUST be fixed for the phase-gate success criterion to hold.

---

## Findings (LIVE, to be fixed this phase)

### F1 — `swipeKeep()` is a permanent alias for `swipeFavorite()` after Phase 1 rewrote its body [SEVERITY: high]
- **File:** `SwipeSort/Features/Swipe/SwipeSessionModel.swift:129-134`
- **Current state:** `swipeKeep()` now records a plain `.keep(...)` and advances — it is **not** an alias for `swipeFavorite()` anymore (Phase 1's W7 fix decoupled them). BUT: the finding's real content still stands under a new form — `swipeKeep` is only called from tests (`SessionResumeTests`, `CommitDeletionsTests`) and never from any production code path. `settings.gestureMode` dispatch (line 236) uses `.swipeFavorite` for the "down"/"left" branches. So `swipeKeep` is now a **test-only public method**, not a production alias. cleanup.md F1 is superseded but the underlying issue (unused-in-production, misleading public surface) is LIVE.
- **Suggested fix:** Delete `swipeKeep()`. Update the 4 test call sites to call `swipeFavorite()` if they're testing the actual production path, or `queue.record(.keep(id))` directly if they're testing decision-queue mechanics without library side effects.
- **Verification path:** grep confirms no non-test caller. `.keep` decisions are still recorded by both `swipeFavorite` and `swipeUp` (via `queue.record`), so tests can be rewritten to use those instead. `SwipeDecision.keep` case stays — it's the queue's representation of "no delete, no move".
- **Source:** cleanup.md F1 + best-practices.md F17 (both flag the same symbol).

### F2 — `GestureMode` doc-comments say "Keep" but user-visible strings say "Fav" [SEVERITY: high]
- **File:** `SwipeSort/Core/AppSettings.swift:12,14`; `SwipeSort/Features/Settings/SettingsView.swift:78-79`
- **Current state:** Confirmed. Doc-comments read "Down = Keep" / "Left = Keep"; `displayName` returns "Mode 1 (Up: Delete, Down: Fav)" / "Mode 2 (Right: Delete, Left: Fav)"; runtime dispatch calls `swipeFavorite()`. Three source-of-truth locations telling different stories.
- **Suggested fix:** Rewrite the two doc-comments to read "Down = Favorite" / "Left = Favorite" and drop the "Keep" phrasing. Simultaneously rename the enum cases to `upDeleteDownFavorite` / `rightDeleteLeftFavorite` — the `rawValue` string used for UserDefaults persistence must stay the same to avoid breaking users' saved settings.
- **Migration:** because `AppSettings` reads via `T(rawValue:)`, keep the `rawValue = "upDeleteDownKeep"` / `"rightDeleteLeftKeep"` string literals unchanged even after renaming the cases; that way existing installs keep their preference.
- **Source:** cleanup.md F2.

### F3 — `SwipeFilter.MediaTypeFilter.livePhotosOnly` is an unreachable dead case [SEVERITY: high]
- **File:** `SwipeSort/Core/SwipeFilter.swift:22,73`
- **Current state:** Confirmed. Case exists, setter groups it with `.any` (no-op), getter never emits it, `nsPredicate()` never generates a predicate for it. No caller anywhere references `.livePhotosOnly`.
- **Suggested fix:** Remove the case entirely. Update the setter's switch to omit it (compiler will enforce exhaustiveness). If Live-Photo filtering is a future need, add a `TODO(future)` comment on `MediaTypeOption` — but do not preserve a dead enum case for that.
- **Source:** cleanup.md F3.

### F4 — `totalPendingCount` is a pure synonym for `pendingDeletions.count` [SEVERITY: medium]
- **File:** `SwipeSort/Features/Swipe/SwipeSessionModel.swift:329-330`
- **Current state:** Confirmed. Single call site: `SwipeStackView.swift:303`. Every other pending-count read uses `model.pendingDeletions.count` directly.
- **Suggested fix:** Delete `totalPendingCount`. Replace the one call site at `SwipeStackView.swift:303` with `model.pendingDeletions.count`.
- **Source:** cleanup.md F4.

### F5 — `DecisionQueue.deleteCount` is unused by all production callers [SEVERITY: medium]
- **File:** `SwipeSort/Core/SwipeDecision.swift:56-61`
- **Current state:** Confirmed. `SwipeSessionModel.pendingDeletions` is the deduplicated view every production site uses. `deleteCount` is a raw-count that only appears in `SwipeDecisionQueueTests`. As cleanup.md notes, retaining a second counting API that can disagree with `pendingDeletions.count` under duplicate-decide is a footgun.
- **Suggested fix:** Delete `deleteCount`. Update the ~10 tests in `SwipeDecisionQueueTests.swift` to count `.delete` decisions directly (`queue.decisions.filter { if case .delete = $0 { true } else { false } }.count`), OR change them to assert on `SwipeSessionModel.pendingDeletions.count` if that better represents the production contract they're pinning. Same treatment for `keepCount` at line 63-69 if it turns out to be unused in production too — verify first.
- **Source:** cleanup.md F5.

### F6 — Duplicate `isPrev` detection logic in three places inside `SwipeStackView` [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:346-357, 700-714, 727-734` (three copies of the same six-line `isVertical`/`isPrev` switch)
- **Current state:** Confirmed. `isDraggingPrev` computed property, `swipeGesture.onChanged`, and `swipeGesture.onEnded` all repeat the same logic.
- **Suggested fix:** Extract `private func isPrevDirection(dx: CGFloat, dy: CGFloat, mode: GestureMode) -> Bool` and call from all three sites. Update `isDraggingPrev` to use it as well.
- **Source:** cleanup.md F14.

### F7 — `shouldAutoplay` ignores its `durationSeconds` parameter [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/SwipeCardView.swift:97-99`
- **Current state:** Confirmed. Body is `return settings.autoplayVideos`. Tests (`SettingsIntegrationTests.swift:78-80,95`) pass 10, 30, 600 seconds — all treated identically.
- **Suggested fix:** Drop the parameter. Callsite at `SwipeCardView.swift:45` becomes `Self.shouldAutoplay(settings: settings)`. Tests update accordingly. If a per-clip threshold is ever wanted, add it with a separate finding and design — do not keep the dead parameter as speculative future-proofing.
- **Source:** cleanup.md F13.

### F8 — "Go Back" button body is duplicated verbatim in `finishedSummary` [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:627-655`
- **Current state:** Confirmed. Two 12-line copies differing only in `.buttonStyle(.borderedProminent)` vs `.buttonStyle(.bordered)`.
- **Suggested fix:** Hoist to one Button and switch the style via a ternary:
  ```swift
  Button { dismiss() } label: { … "Go Back" … }
      .buttonStyle(
          (model.pendingDeletions.isEmpty || commitResult != nil)
              ? AnyButtonStyle(BorderedProminentButtonStyle())
              : AnyButtonStyle(BorderedButtonStyle())
      )
  ```
  If `AnyButtonStyle` erasure is awkward, use a `@ViewBuilder` helper that wraps the button and applies the style inside.
- **Source:** cleanup.md F15.

### F9 — `queueGrid` inner `if !model.pendingDeletions.isEmpty` is always true [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/ReviewCommitView.swift:64`
- **Current state:** Confirmed. Caller at line 19 branches on `pendingDeletions.isEmpty`; the inner guard is dead.
- **Suggested fix:** Remove the inner `if` wrapper and dedent the `Text` and `LazyVGrid`. The outer branch guarantees non-empty.
- **Source:** cleanup.md F16.

### F10 — `SwipeSessionModel.toggleFavorite` is defined but has no production caller [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/SwipeSessionModel.swift:209-212`
- **Current state:** Confirmed. Only the doc-comment in `swipeKeep` (line 120) references `toggleFavorite`; no view calls it. UI still lacks a dedicated ♥ button.
- **Suggested fix:** Delete the method. If the design ever wants a ♥ button that toggles favourite without advancing, add it back at that time with the button. Zombie API is worse than deferred API — the tests that exercise it currently pin a contract the app doesn't actually depend on.
- **Source:** cleanup.md F20.

### F11 — `ThemeMode.displayName` is redundant with capitalised rawValue [SEVERITY: low]
- **File:** `SwipeSort/Features/Settings/SettingsView.swift:65-73`
- **Current state:** Confirmed. Returns "System"/"Light"/"Dark" — exactly `rawValue.capitalized`. Since only three cases, the fix is either capitalise `rawValue`s to match and use `.rawValue` in the picker, or replace `.displayName` with `.rawValue.capitalized`.
- **Suggested fix:** Replace the extension body with a single `rawValue.capitalized` return — matches convention for `Codable` interop without changing UserDefaults schema (rawValue stays lowercase in defaults).
- **Source:** cleanup.md F11.

### F12 — `GestureMode.displayName` duplicates enum semantics that live in doc-comments [SEVERITY: low]
- **File:** `SwipeSort/Features/Settings/SettingsView.swift:75-82`
- **Current state:** Related to F2 above. `displayName` says "Fav" while doc says "Keep". After F2's fix, the terms will match, but the duplication remains: the human-readable mapping is encoded in two places.
- **Suggested fix:** After F2's rename, leave `displayName` alone — it is the UI presentation string and the enum doc is the developer-facing description; two views of the same data at different layers is acceptable. Update this finding to WON'T-FIX with rationale in the phase-7 plan.
- **Source:** cleanup.md F12.

### F13 — `@Bindable var s = settings` re-allocates on every body evaluation [SEVERITY: low]
- **File:** `SwipeSort/Features/Settings/SettingsView.swift:13`
- **Current state:** Confirmed. Idiomatic Swift 5.9+ is `@Bindable @Environment(AppSettings.self) private var settings`.
- **Suggested fix:** Replace the two lines
  ```swift
  @Environment(AppSettings.self) private var settings
  ...
  @Bindable var s = settings
  ```
  with
  ```swift
  @Environment(AppSettings.self) @Bindable private var settings
  ```
  Then replace `$s.themeMode` etc. with `$settings.themeMode`. Verify at compile time in Xcode.
- **Source:** best-practices.md F11.

### F14 — Cross-file namespace confusion: `DeletionQueueView` lives in `ReviewCommitView.swift` [SEVERITY: low]
- **File:** `SwipeSort/Features/Swipe/ReviewCommitView.swift`
- **Current state:** Confirmed. File name suggests a review-before-commit view; the only public type inside is `DeletionQueueView`. No struct named `ReviewCommitView` exists.
- **Suggested fix:** Rename the file to `DeletionQueueView.swift`. Move the private `QueueThumbnailCell` along with it (already inside). Update any reference in `docs/reviews/2026-07-13/README.md`'s file-map.
- **Source:** architecture.md F12.

### F15 — `SwipePresentationContext` lives in `RecentsView.swift` but is shared with `AlbumsView.swift` [SEVERITY: low]
- **File:** already fixed: `SwipeSort/Features/Components/SwipePresentationContext.swift` (Phase 3 moved it there). Verify no stale forward-reference in `RecentsView.swift`. If a duplicate definition remains, remove it.
- **Current state:** VERIFY. `SwipePresentationContext.swift` exists at the expected location. Confirm `RecentsView.swift` and `AlbumsView.swift` do not re-declare it.
- **Suggested fix:** If already CLOSED by Phase 3, mark the finding closed in this phase's summary. No code change needed.
- **Source:** architecture.md F14.

### F16 — `AlbumGridView.getScopedLibrary()` imperative memoisation pattern [SEVERITY: low]
- **File:** `SwipeSort/Features/Landing/AlbumsView.swift:138-140,246-249`
- **Current state:** Reviewed the current code — `scopedLibrary` is a plain `@State` var set once in `.task(id: album.id) { scopedLibrary = library.scoped(toAlbumId: album.id) }`. The original `getScopedLibrary()` imperative pattern is GONE (Phase 3 rewrote it). Finding is CLOSED.
- **Suggested fix:** No action; mark closed in summary.
- **Source:** architecture.md F13.

### F17 — Missing tests: pin the bug-prone edge cases the earlier phases left uncovered [SEVERITY: low]
- **Files:** `SwipeSortTests/*`
- **Current state:** From testing.md, still LIVE (unless already added by Phase 5 — verify):
  - F14: `WindowedThumbnailCacheTests` lacks a `total == 0` boundary test.
  - F16: `SwipeSortUITestsLaunchTests.testLaunch()` still has no assertions.
  - F18: no test for `swipePrev` when all prior photos are decided (queue full).
  - F19: `SettingsIntegrationTests` doesn't test the `down` direction in Mode 2 (`swipePrev` gesture in mode 2).
  - F20: no unit test for `SwipeSessionModel.removeFromDeletionQueue(_:)`.
- **Suggested fix:** Add each test. Individually small, but the total is 5 small test cases across 3 files. Since Phase 7 is about cleanup, we should decide per-item whether to add or defer to a proper Phase 5 addendum. Recommendation: add all five inline this phase — they are quick pins for behaviour we've already stabilised and add no new production code.
- **Source:** testing.md F14/F16/F18/F19/F20.

### F18 — Silent truncation caps in grids: 500 (Recents) / 1000 (Album) [SEVERITY: low]
- **File:** `SwipeSort/Features/Landing/RecentsView.swift:144`; `SwipeSort/Features/Landing/AlbumsView.swift:264`
- **Current state:** Confirmed. Both grids `min(count, N)`-cap the identifier fetch. Users with more photos in an album than N see silent truncation.
- **Suggested fix:** Won't-fix in Phase 7 (pagination is a design change, not cleanup). Add a `// TODO(pagination):` marker to each site so the intent is documented; the marker is discoverable via grep for a future pagination pass.
- **Source:** performance.md F13.

---

## Findings CLOSED by earlier phases (spot-verified)

- cleanup.md F7 (SwipeDecision v0.1 comment) — no `v0.` refs remain in code.
- cleanup.md F8 (PhotoKitLibrary caching-window v0.1 comment) — comment rewritten during Phase 4.
- cleanup.md F9 (`ThumbnailCell` / `GridImageCache` / `GridSelectionBottomBar` in wrong files) — all now in `Features/Components/`. Phase 3.
- cleanup.md F10 (Duplicated grid body between `RecentsView` and `AlbumGridView`) — both use `PhotoGridView` now. Phase 3.
- cleanup.md F17 (`MockPhotoLibrary.removeAssetsFromAlbum` doesn't record) — `lastRemoves` array added. Phase 2 or 5.
- cleanup.md F18 (`PhotoLibraryProviding` v0.2 comment) — rewritten in Phase 3.
- cleanup.md F19 (three caching methods) — protocol comment already documents pairing invariant.
- cleanup.md F6 (v0.3 `ReviewedAssetStore` doc-comment on `SwipeSessionModel`) — no such text in current doc; the class doc-comment describes actual behavior. Phase 1 rewrote.
- best-practices.md F1, F2 (`@unchecked Sendable`) — both classes now `@MainActor`. Phase 2.
- best-practices.md F3 (VoiceOver on SwipeCard), F4 (haptic prepare), F5 (44 pt tap target), F13 (badge announcement), F14 (finished-summary announcement), F15 (Info.plist), F16 (reduce motion), F19 (dynamic type hint) — all done in Phase 6.
- best-practices.md F6 (SwipeStackView `.task` id), F7 (finishedSummary `.task` id), F8 (`queue` visibility), F10 (`AppSettings.dryRunMode`) — all closed by Phase 3/4.
- best-practices.md F18 (PhotoLibraryCacheProviding `@MainActor`), F20 (`AlbumPickerSheet.task(id:)`) — closed by Phase 2/3.
- correctness.md F17 (album fetch stampede), F18 (`DryRunMode.isEnabled` static-var read) — closed by Phase 4 / Phase 3 (dryRunMode is gone from AppSettings entirely).
- performance.md F14 (VideoPlayerPool AVAsset resource-loading cancel) — WON'T-FIX. Photos-managed AVAssets typically deliver via a completion handler at fetch time; canceling the `PHImageManager.requestPlayerItem` request separately requires storing the request id, which is a design change beyond cleanup scope. Add TODO comment.
- testing.md F13 (`AlbumMoveTests` undo coverage) — verify against Phase 5 additions; may already be covered.

---

## Categorised list (for planning)

### Dead-code removal (must-do)
- F1 `swipeKeep()`
- F3 `SwipeFilter.MediaTypeFilter.livePhotosOnly`
- F4 `totalPendingCount`
- F5 `DecisionQueue.deleteCount` (and possibly `keepCount`)
- F7 `shouldAutoplay(durationSeconds:)` parameter
- F10 `SwipeSessionModel.toggleFavorite`
- F9 dead inner `if` in `ReviewCommitView.queueGrid`

### Naming / semantic-consistency
- F2 `GestureMode` doc-comments + case names (keep-vs-favorite mismatch)

### DRY / readability
- F6 duplicate `isPrev` detection (3× in `SwipeStackView`)
- F8 duplicate "Go Back" button body
- F11 `ThemeMode.displayName` extension is redundant
- F13 `@Bindable var s = settings` idiom

### File / namespace organisation
- F14 rename `ReviewCommitView.swift` → `DeletionQueueView.swift`

### Test-coverage pins
- F17 five small test additions (WindowedThumbnailCache zero-total, UITest launch assertions, swipePrev fully-decided, Mode2 down, `removeFromDeletionQueue`)

### Deferred / won't-fix
- F12 `GestureMode.displayName` duplication with enum doc (WON'T-FIX after F2 aligns the words)
- F15 verify already-closed
- F16 verify already-closed
- F18 pagination TODOs
- performance.md F14 AVAsset cancel TODO

---

## Success criterion recap
Phase-7 gate: **no `high` findings anywhere.** After fixing F1, F2, F3 above (the three `high` items from cleanup.md) plus the remaining LIVE meds and lows above, the final adversarial re-review should surface only new findings introduced by Phase 7 itself (which the whole-branch reviewer will catch). Any remaining stale `high` finding is a fail.
