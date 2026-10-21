# Phase 5 Working Set — Re-verification of Testing-Lens Findings
**Date:** 2026-07-15  **Re-verifier:** re-verification pass after Phases 1–4

## Summary

After Phases 1–4 the original 20 testing-lens findings resolve as follows:
- **CLOSED:** 5 (F6, F11, F12, F14, F15)
- **LIVE:** 13 (F1, F2, F3, F4, F5, F7, F8, F9, F10, F13, F17, F18, F19, F20)
- **PARTIAL:** 1 (F16)
- **SUPERSEDED:** 1 (F16 — see below; reassigned to PARTIAL)

---

## Finding-by-Finding Status Table

| Finding | Status | Anchor (file:line) | Current status |
|---------|--------|--------------------|----------------|
| F1 | LIVE | `SwipeSort/Core/MockPhotoLibrary.swift:150` | `removeAssetsFromAlbum` at line 150–153 still always returns `.success` — no `nextRemoveResult` scripting hook exists. `undo()` in `SwipeSessionModel.swift:282` calls it and logs but discards the result; no test in `AlbumMoveTests.swift` exercises the failure path. |
| F2 | LIVE | `SwipeSortTests/SessionResumeTests.swift` (no `.finished`→undo test) | `undo()` at `SwipeSessionModel.swift:311` unconditionally sets `phase = .ready`. No test starts a 2-asset session, advances to `.finished`, then calls `undo()` to confirm `phase == .ready` and `currentThumbnail != nil`. `SessionResumeTests.swift` only tests `undoRemovesDecision` from a mid-session state. |
| F3 | LIVE | `SwipeSortTests/SwipeSessionModelTests.swift` (no concurrent swipe test) | No test uses `async let` to dispatch concurrent `swipeDelete()`/`swipeKeep()` calls. The double-swipe guard noted in Phase 1 mitigates the model-layer risk, but no regression test pins the boundary (e.g., exactly 2 unique identifiers in queue when two swipes fire on a 2-asset library). |
| F4 | LIVE | `SwipeSortTests/SwipeSessionModelTests.swift:471–503` | The only `PhotoLibraryChangePublisher` tests (lines 471–503) verify idempotency of `register()` — neither drives `refreshFetchResult()` on `MockPhotoLibrary` mid-session nor asserts that `currentIndex` stays valid after a cursor refresh. `MockPhotoLibrary.refreshFetchResult()` remains a no-op at `MockPhotoLibrary.swift:200`. |
| F5 | LIVE | `SwipeSort/Core/MockPhotoLibrary.swift:24` | `currentAuth` at line 24 is `private` with no exposed setter or `setCurrentAuthorization` method. `SwipeSessionModel.start()` only checks auth at startup (line 86); no test scripts auth revocation after `phase == .ready`. |
| F6 | CLOSED | — | Phase 1 fixed the correctness bug and Phase 1 added `commitDecisionsFailedRevertsToReady` test at `SwipeSessionModelTests.swift:188–200`. The `phase = .finished` guard is now inside `case .success` at `SwipeSessionModel.swift:377–378`. Both `.failed` behavior and phase invariant are now tested. |
| F7 | LIVE | `SwipeSortUITests/SwipeSortUITests.swift` (no Mode 2 UI test) | All four gesture-driven UI tests (`testSwipeLeftSkipsCardAndAdvancesDeck`, `testUndoActionRewindsCard`, `testSinglePhotoSwipeTransitionsToFinishedSummary`, `testOpenSwipeDeckFromGridAndClose`) use default gesture mode. No UI test navigates to Settings, selects Mode 2 (`rightDeleteLeftKeep`), then verifies swipe-right triggers delete. |
| F8 | LIVE | `SwipeSortUITests/SwipeSortUITests.swift:119` | `testEmptyPhotoLibraryDisplaysEmptyState` (line 119–128) verifies grid empty-state text only. No assertion checks that tapping into the swipe deck from an empty library immediately shows `FinishedSummaryView` rather than a blank card area. |
| F9 | LIVE | `SwipeSort/Core/MockPhotoLibrary.swift:105` | `MockPhotoLibrary.thumbnail(for:targetSize:)` at line 105–114 always returns a non-nil `AssetThumbnail` with `isDegraded: false`. No `nextThumbnailResult` scripting slot exists; no test verifies `SwipeSessionModel` behavior when `currentThumbnail` becomes nil mid-session or when a degraded-then-final sequence is delivered. |
| F10 | LIVE | `SwipeSortTests/ApplyFilterRefreshTests.swift` | `ApplyFilterRefreshTests.swift` only tests that `applyFilter` on the mock produces consistent identifiers — it does not start a `SwipeSessionModel` session, call `applyFilter` with a different filter mid-session, then assert that the session resets or handles the invalidated index space. The doc-level warning in `PhotoLibraryProviding` is unenforced. |
| F11 | CLOSED | — | Phase 3 moved `dryRunMode` off `AppSettings`. `DebugMenuTests.swift` was updated: it now has two tests (`toggleWritesDefaults` and `existingValuePreserved` at lines 8–33) that cover the `DryRunMode` persistence contract and the `AppSettings` migration scenario. No longer a stub. |
| F12 | CLOSED | — | Phase 1 decoupled `swipeKeep` from `setFavorite`. `SwipeSessionModelTests.swift:404–418` (`swipeKeepDoesNotFavorite`) now asserts `mock.favoriteState[firstId] == nil` after `swipeKeep()` and `swipeFavoriteSetsIsFavorite` asserts `mock.favoriteState[firstId] == true` after `swipeFavorite()`. The finding's original premise is fully inverted and pinned. |
| F13 | LIVE | `SwipeSortTests/AlbumMoveTests.swift` (no undo test) | `AlbumMoveTests.swift` has no test calling `undo()` at all. The two undo paths in `SwipeSessionModel.undo()` (nil `fromAlbumId` → `removeAssetsFromAlbum` at line 282; non-nil → `moveAssets` reversed at line 276) are untested against both source-album variants. The only undo test covering `removeAssetsFromAlbum` is the dry-run gate test in `SwipeSessionModelTests.swift:434`. |
| F14 | CLOSED | — | Phase 4 added the `lower < upper` guard in `WindowedThumbnailCache.slide(to:total:)` at `WindowedThumbnailCache.swift:66–76`. Additionally `WindowedThumbnailCacheTests.swift` now includes `windowClamps` (line 84) which tests a 4-asset library, and the sparse/dense batch tests. Although no explicit `slide(to: 0, total: 0)` test exists, the guard path (`lower < upper` fails → no caching calls issued) is exercised defensively by the `windowClamps` test with a total of 4. The finding's stated risk (underflow to huge Range) is closed by the guard. The zero-total dedicated assertion is still absent but the behavior is correct and guarded. **Status: PARTIAL** — guard is present and correct, dedicated `total == 0` test still missing. |
| F15 | CLOSED | — | Phase 4 removed `cardPixelSize` as a fixed init constant. `SwipeStackView.swift` now computes a fallback at init (line 56) and overwrites it via `model.configure(targetSize:)` in `.task` (line 98). `SwipeSessionModel.configure(targetSize:)` is tested at `SwipeSessionModelTests.swift:457–468`. |
| F16 | PARTIAL | `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift:21` | `testLaunch()` at line 21–34 still only takes a screenshot with no assertions. It does not call `app.wait(for: .runningForeground, timeout:)` or assert any UI element exists. A crash at launch would not be caught. |
| F17 | LIVE | `SwipeSortTests/BulkDeleteTests.swift:14` | `deleteAllSubmitsBatch` at line 9–24 applies a `screenshotsOnly` filter then asserts all 5 identifiers — the mock ignores the filter predicate and `assetIdentifier(at:)` returns `mock-asset-N` regardless. The test asserts mock behavior, not real predicate filtering. `scriptedFilteredCount` is not set in this test, so the filter has no effect on the effective count. |
| F18 | LIVE | `SwipeSortTests/SwipeSessionModelTests.swift` (no all-prior-decided swipePrev test) | The existing `swipePrevNavigatesToPreviousIndex` test (line 114) covers a single decided asset. No test starts with all prior assets decided, calls `swipePrev()` from index 0, and asserts `currentIndex` is unchanged (the `guard currentIndex > 0` no-op path at `SwipeSessionModel.swift:229`). |
| F19 | LIVE | `SwipeSortTests/SettingsIntegrationTests.swift` | `SettingsIntegrationTests.swift` has tests for Mode 1 up/down (line 24), Mode 1 left-next (line 39), Mode 2 right/left (line 49), and Mode 2 up-next (line 64). Missing: Mode 1 `.right` → `swipePrev` and Mode 2 `.down` → `swipePrev`. Both missing swipePrev direction dispatches are untested at the integration level. |
| F20 | LIVE | `SwipeSortTests/` (no `removeFromDeletionQueue` model test) | `SwipeSessionModel.removeFromDeletionQueue(_:)` at `SwipeSessionModel.swift:345` is not covered by any unit test. No test starts a session, queues 3 deletions, calls `removeFromDeletionQueue` on the middle one, and asserts `pendingDeletions.count == 2` with the middle identifier absent. `SwipeDecisionQueueTests` covers `removeDecision` at the queue level only. |

---

## Phase 5 Planning Targets

### Ready for Phase 5 (LIVE + PARTIAL + SUPERSEDED)

**High severity:**
- **F1** — Add `nextRemoveResult: CommitResult?` to `MockPhotoLibrary`; write undo-failure test in `AlbumMoveTests.swift`
- **F2** — Add test: 2-asset session → swipe both → `.finished` → `undo()` → assert `phase == .ready` and `currentThumbnail != nil`
- **F4** — Add mid-session `refreshFetchResult` scenario test; drive `SwipeSessionModel` after cursor refresh and assert correct asset
- **F5** — Expose `setCurrentAuthorization(_:)` on `MockPhotoLibrary`; add mid-session revocation test

**Medium severity:**
- **F3** — Add concurrent-swipe regression test using `async let`
- **F7** — Add UI test: launch with `--ui-testing`, navigate Settings, select Mode 2, swipe-right, assert delete badge increments
- **F8** — Extend `testEmptyPhotoLibraryDisplaysEmptyState` to navigate to swipe deck and assert `FinishedSummaryView` is shown
- **F9** — Add `nextThumbnailResult: AssetThumbnail??` to `MockPhotoLibrary`; add nil-thumbnail and degraded-delivery tests
- **F10** — Add test: start session, call `applyFilter` with different filter, advance, assert graceful handling
- **F13** — Add two undo tests to `AlbumMoveTests.swift`: nil-source (expects `removeAssetsFromAlbum`) and non-nil-source (expects reversed `moveAssets`)

**Low severity:**
- **F14 (PARTIAL)** — Add explicit `slide(to: 0, total: 0)` test asserting `startCachingCalls.isEmpty`
- **F16 (PARTIAL)** — Add `XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))` and a root nav-bar existence check to `testLaunch()`
- **F17** — Set `scriptedFilteredCount` in `deleteAllSubmitsBatch` to reflect filter scope, or add a separate predicate-logic test
- **F18** — Add test: swipePrev at index 0 is a no-op (`currentIndex` stays 0)
- **F19** — Add `mode1RightPrev` and `mode2DownPrev` tests to `SettingsIntegrationTests.swift`
- **F20** — Add test: 3 deletes queued → `removeFromDeletionQueue(middle)` → assert `pendingDeletions.count == 2` and middle absent

### Dropped (CLOSED by Phases 1–4)

- **F6** — Closed by Phase 1: `.failed` path now tested in `SwipeSessionModelTests.swift:188`; `phase = .finished` guard is inside `case .success`
- **F11** — Closed by Phase 3: `DebugMenuTests.swift` updated with migration scenario test; no longer a stub
- **F12** — Closed by Phase 1: `swipeKeep`/`swipeFavorite` decoupled; `swipeKeepDoesNotFavorite` test asserts `favoriteState[firstId] == nil`
- **F14** — Closed by Phase 4: `lower < upper` guard prevents underflow; behavior is correct (PARTIAL note: zero-total dedicated test still absent but non-blocking)
- **F15** — Closed by Phase 4: `cardPixelSize` removed; `configure(targetSize:)` added and tested
