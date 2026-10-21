# Test Coverage & Edge Cases
**Reviewer:** testing-lens  **Date:** 2026-07-13  **Verify status:** pass

## Summary

The unit test suite (13 files, 1,061 lines) has solid coverage of the happy paths in `SwipeSessionModel`, `DecisionQueue`, `MockPhotoLibrary`, `SwipeFilter`, and `WindowedThumbnailCache`. However, the mock is a faithful stub for the *success* path only: it does not model iCloud latency, `localIdentifier` disappearance after a delete, or batch-move errors that the real `PhotoKitLibrary` can return. The `UITests` target exercises tab navigation and a single gesture direction per gesture mode but never drives the full 4-way gesture matrix, never tests Mode 2 end-to-end through the deck, and has no denied-auth mid-session or library-change-observer scenario. Multiple high-severity gaps exist around `undo` of `moveToAlbum` when `fromAlbumId` is nil (real-library semantics vs mock lie), phase transitions under commit cancellation, and the complete absence of tests for the `PHPhotoLibraryChangeObserver` integration path.

## Findings

### F1 — `removeAssetsFromAlbum` mock always returns success — undo of moveToAlbum (nil source) untested against realistic failure [SEVERITY: high]
- **File:** `SwipeSortTests/AlbumMoveTests.swift` (no test) + `SwipeSort/Core/MockPhotoLibrary.swift:127`
- **What:** `MockPhotoLibrary.removeAssetsFromAlbum` unconditionally returns `.success` with no scripting hook, so the undo-of-moveToAlbum code path in `SwipeSessionModel.undo()` (lines 170–174) is never exercised against a failure outcome, and no test verifies the queue rollback when removal fails.
- **Why it matters / failure scenario:** A real album that does not permit `removeContent` (smart album or restricted album) returns `.failed`; the mock silently succeeds. The session model ignores the return value of `removeAssetsFromAlbum`, so the asset is removed from the queue but may remain in the destination album — the user believes the undo worked but the asset is still moved.
- **Suggested fix direction:** Add `nextRemoveResult: CommitResult?` scripting slot to `MockPhotoLibrary` (parallel to `nextCommitResult`). Write a test that scripts `.failed` and asserts the queue decision is *not* removed (or that the caller surfaces an error).
- **Verified:** yes (adversarial subagent confirmed — no scripting hook, `undo()` at line 173 discards the result via `_ =`, no undo test in AlbumMoveTests)

### F2 — No test for undo of `moveToAlbum` across a phase change (`.ready` → `.finished` → undo) [SEVERITY: high]
- **File:** `SwipeSortTests/SessionResumeTests.swift` (no such test)
- **What:** `SwipeSessionModel.undo()` unconditionally sets `phase = .ready` (line 192) even when called from `.finished`; no test verifies this transition or checks that `currentThumbnail` is correctly restored after the session has already transitioned to `.finished`.
- **Why it matters / failure scenario:** User swipes the last photo → session transitions to `.finished`, summary shown → user taps Undo → `phase` flips back to `.ready` but `currentThumbnail` must be reloaded; if the library has been invalidated by the observer between swipe and undo the thumbnail fetch may return nil, leaving the UI stuck in `.ready` with no card.
- **Suggested fix direction:** Add a test that starts a 2-asset session, swipes both (transition to `.finished`), calls `undo()`, and asserts `phase == .ready` and `currentThumbnail != nil`.
- **Verified:** yes (adversarial subagent confirmed — `undo()` at line 192 sets `phase = .ready` unconditionally regardless of prior phase; no existing test starts from `.finished`)

### F3 — Rapid swipe spam (concurrent calls) not tested; `advance()` has no re-entrancy guard [SEVERITY: medium]
- **File:** `SwipeSortTests/SwipeSessionModelTests.swift` (no concurrency test)
- **What:** `SwipeSessionModel` is `@MainActor` but its async `advance()` method suspends while awaiting `loadCurrent()`. If two swipe actions are dispatched simultaneously (e.g., the gesture fires twice before the first `await` resolves) `currentIndex` can be incremented twice and `queue.decisions` can receive duplicate entries for the same asset.
- **Why it matters / failure scenario:** User swipes quickly on a slow iCloud device; two `swipeDelete()` calls are dispatched before the first `loadCurrent()` returns. Both read the same `currentThumbnail`, both record `.delete(id)` for the same asset, and `currentIndex` overshoots, potentially crashing with `assetIdentifier(at:)` returning nil at an out-of-bounds index.
- **Suggested fix direction:** Add a unit test that calls `swipeDelete()` and `swipeKeep()` concurrently (via `async let`) on a 2-asset library and asserts that exactly 2 unique identifiers appear in `queue.decisions`. Then add a guard in `SwipeSessionModel` (a dedicated finding for the architecture lens) — but this test needs to exist first to catch regressions.
- **Verified:** plausible — severity revised high → medium. `@MainActor` serialises calls at the model layer so the double-increment scenario cannot occur within the model; the risk is real at the view layer (gesture double-dispatch), not the model layer. Regression test for the boundary is still worthwhile.

### F4 — No test for `PHPhotoLibraryChangeObserver` mid-session (identifier shift) [SEVERITY: high]
- **File:** `SwipeSortTests/` (no change-observer test exists)
- **What:** `PhotoLibraryChangePublisher` posts a `didChangeNotification` whenever the library changes, but no unit or integration test verifies what happens when `refreshFetchResult()` is called on `MockPhotoLibrary` while a `SwipeSessionModel` session is active (i.e., the index space shifts under the cursor).
- **Why it matters / failure scenario:** External app (iMessage, iCloud sync) adds/removes photos while a swipe session runs. `refreshFetchResult()` clears the cursor; the next `assetIdentifier(at: currentIndex)` returns a different photo or nil. The session model does not re-validate `currentIndex` after a refresh, so `currentThumbnail` may display the wrong photo or become nil while `phase` stays `.ready`.
- **Suggested fix direction:** Add a `MockPhotoLibrary` method that simulates a cursor refresh (e.g., remove an asset by index) and a test that calls `refreshFetchResult()` mid-session, then calls `swipeKeep()`, asserting the correct asset is recorded and the phase is still `.ready`.
- **Verified:** yes (adversarial subagent confirmed — `refreshFetchResult()` is a documented no-op in mock; grep confirms no test file references the change-observer path; session model has no re-validation mechanism after refresh)

### F5 — Auth denied mid-session not tested; `SwipeSessionModel` has no `.denied` guard on active sessions [SEVERITY: high]
- **File:** `SwipeSortTests/SwipeSessionModelTests.swift` (only covers denied *at start*, not mid-session)
- **What:** `SwipeSessionModel.start()` tests cover the `.denied` authorization state at startup, but no test scripts auth being revoked *after* `phase == .ready` (e.g., user denies in Settings while the app is in the foreground).
- **Why it matters / failure scenario:** User revokes access → `PhotoKitLibrary.currentAuthorization()` returns `.denied` → subsequent `assetIdentifier(at:)` calls return empty fetch results → the model continues advancing through phantom assets, ultimately indexing into the now-empty `PHFetchResult`. The real library returns `.photo` for all `mediaKind(for:)` calls even when the asset is gone; the session shows a blank card indefinitely.
- **Suggested fix direction:** Add a `MockPhotoLibrary` scripting hook to switch authorization mid-flight. Add a test that grants access, starts the session, switches to `.denied`, calls `swipeKeep()`, and asserts the model transitions to `.denied` or surfaces an error.
- **Verified:** yes (adversarial subagent confirmed — `currentAuth` is private with no mid-session mutation hook; `SwipeSessionModel` only checks auth in `start()`; no test scripts revocation after `.ready`)

### F6 — iCloud download failure at commit not tested via mock [SEVERITY: high]
- **File:** `SwipeSortTests/CommitDeletionsTests.swift` (only tests `.cancelledByUser` and `.success`)
- **What:** `CommitResult` has a `.failed(reason:)` case but no `CommitDeletionsTests` test scripts it. `MockPhotoLibrary.commitDeletions` honors `nextCommitResult` for cancel but `.failed` is never injected.
- **Why it matters / failure scenario:** Real `PhotoKitLibrary.commitDeletions` can return `.failed` when the system deletion prompt fails (e.g., iCloud asset not fully downloaded — Photos rejects the deletion). No test asserts how `SwipeSessionModel.commitDecisions()` propagates `.failed` to the caller; the `queue.removeCommitted()` call (line 251) is guarded by `if case .success`, so `.failed` should leave the queue intact — but this is untested and could regress.
- **Suggested fix direction:** Add a test that scripts `nextCommitResult = .failed(reason: "iCloud error")`, calls `commitDecisions()`, and asserts (a) the result is `.failed`, (b) `pendingDeletions` is unchanged, and (c) `phase` is not `.finished` after the failure (currently it is set to `.finished` unconditionally on line 247 — a likely correctness bug this test would expose).
- **Verified:** yes (adversarial subagent confirmed — `.failed(reason:)` never scripted in CommitDeletionsTests; source shows `phase = .finished` set unconditionally before the `if case .success` guard, exposing correctness bug F6 in the correctness lens)

### F7 — UI tests cover only `gestureMode == .upDeleteDownKeep`; Mode 2 gesture flow untested end-to-end [SEVERITY: medium]
- **File:** `SwipeSortUITests/SwipeSortUITests.swift:56` (only swipeLeft/swipeUp)
- **What:** All gesture-driven UI tests (`testSwipeLeftSkipsCardAndAdvancesDeck`, `testUndoActionRewindsCard`, `testSinglePhotoSwipeTransitionsToFinishedSummary`) use `swipeLeft()` or `swipeUp()` without switching the gesture mode setting. Mode 2 (`rightDeleteLeftKeep`) — where left = favorite and right = delete — is never validated at the UI level.
- **Why it matters / failure scenario:** A regression in the `gestureMode` dispatch table in `SwipeStackView.swipeGesture` (lines 577–624) — e.g., modes accidentally swapped — would not be caught by any UI test. The only Mode 2 coverage is a single unit test in `SettingsIntegrationTests.swift` which does not drive the gesture layer.
- **Suggested fix direction:** Add a UI test that launches with `--ui-testing`, navigates to Settings, selects Mode 2, returns to the deck, and performs a swipe-right. Assert the progress counter advances and that the delete badge increments (not stays at 0).
- **Verified:** pending

### F8 — Empty library (assetCount 0) swipe start: unit test exists but UI test `--ui-testing-empty` only verifies grid, not swipe deck [SEVERITY: medium]
- **File:** `SwipeSortUITests/SwipeSortUITests.swift:119` (`testEmptyPhotoLibraryDisplaysEmptyState`)
- **What:** `testEmptyPhotoLibraryDisplaysEmptyState` verifies the grid's empty-state text but does not attempt to open the swipe deck from an empty library. `SessionResumeTests.emptyLibraryFinishes()` covers the model, but no UI test verifies the deck UI state when `assetCount == 0` (the `.finished` phase is entered immediately — the test should verify the finished summary is shown rather than the swipe card area).
- **Why it matters / failure scenario:** A regression in the `SwipeStackView.cardArea` switch statement for `.finished` phase shown immediately (without any `.ready` phase) could produce an incorrect UI (e.g., a blank card area instead of the finished summary), and would not be caught by the grid-only UI test.
- **Suggested fix direction:** Extend `testEmptyPhotoLibraryDisplaysEmptyState` to also tap `ThumbnailCell-0` and assert it does not exist (empty library), or launch `--ui-testing-empty` and directly launch the swipe stack, asserting `FinishedSummaryView` is visible.
- **Verified:** pending

### F9 — `MockPhotoLibrary.thumbnail` never returns `nil` or a degraded image; iCloud latency not modelable [SEVERITY: medium]
- **File:** `SwipeSort/Core/MockPhotoLibrary.swift:83`
- **What:** `thumbnail(for:targetSize:)` always returns a valid `AssetThumbnail` with `isDegraded: false`. There is no scripting hook to return `nil` (download failure) or `isDegraded: true` (progressive delivery still in progress).
- **Why it matters / failure scenario:** `SwipeSessionModel.loadCurrent()` assigns the result of `thumbnail(for:)` directly to `currentThumbnail`. If the real library returns `nil` (asset deleted externally during session, or iCloud timeout), `currentThumbnail` becomes nil while `phase` stays `.ready`, and `SwipeCardView` receives a nil thumbnail — its behavior in this case is not tested. Additionally, tests never verify that progressive-delivery updates (repeated non-nil calls with `isDegraded: true` followed by a final `isDegraded: false`) are handled correctly.
- **Suggested fix direction:** Add `nextThumbnailResult: AssetThumbnail??` (double optional) scripting slot. Write tests for (a) nil thumbnail mid-session — does the UI gracefully handle a blank card? and (b) degraded-then-final delivery sequence.
- **Verified:** pending

### F10 — Filter change mid-session: doc says "don't", but no enforcement test exists [SEVERITY: medium]
- **File:** `SwipeSortTests/SwipeFilterTests.swift` (no mid-session filter change test); `SwipeSort/Core/PhotoLibraryProviding.swift:123` (protocol doc warns against it)
- **What:** The `applyFilter` doc comment states "MUST be called before `SwipeSessionModel.start()` … filter changes mid-session yield an inconsistent index space." There is no test that calls `applyFilter` on an active session and asserts either (a) a precondition/assertion fires, (b) the session is reset, or (c) the behavior is at least documented to be undefined/ignored.
- **Why it matters / failure scenario:** `SwipeStackView.body` calls `await library.applyFilter(filter)` inside the `.task` modifier (line 87) — before `model.start()`. But if the view is dismissed and re-presented with a different filter while holding a reference to the same library, `applyFilter` clears the `PHCachingImageManager` and resets `fetchResult` (lines 480–485 of `PhotoKitLibrary`). Any previously captured `currentIndex` is now wrong. No test catches this scenario.
- **Suggested fix direction:** Add a test that starts a session, calls `applyFilter` with a different filter, then attempts to advance, and asserts the model either handles the index-space invalidation gracefully (e.g., resets to index 0) or that `SwipeStackView`'s `init` with a new filter always triggers a fresh session start.
- **Verified:** pending

### F11 — `DebugMenuTests` is a duplicate of `DryRunModeTests` with one test; the test name is misleading [SEVERITY: medium]
- **File:** `SwipeSortTests/DebugMenuTests.swift:1`
- **What:** `DebugMenuTests` contains exactly one test (`toggleWritesDefaults`) which is functionally identical to `DryRunModeTests.persists()`. No test in `DebugMenuTests` covers the debug menu's UI (nor the dry-run gate's effect on destructive operations). The file exists purely as a placeholder.
- **Why it matters / failure scenario:** The dry-run gate in `PhotoKitLibrary` (lines 126–129, 212–215, 266–269) — the kill-switch for destructive PhotoKit operations — is only tested indirectly through `DryRunModeTests` (which only checks `UserDefaults` round-trip, not the actual gate behavior). A regression where `DryRunMode.isEnabled` returns the wrong value in the live `PhotoKitLibrary` context would not be caught.
- **Suggested fix direction:** Delete the redundant `DebugMenuTests` or repurpose it to test the dry-run gate behavior on `MockPhotoLibrary` (assert `commitDeletions` is not called when dry-run is on). Replace the placeholder with a test that scripts `DryRunMode.setEnabled(true)` and then calls a destructive operation, asserting it returns `.success` without hitting the mock's commit path.
- **Verified:** pending

### F12 — `swipeKeep` / `swipeFavorite` alias not tested: both call `setFavorite` but the keep-count is attributed to "favorite" not "keep" [SEVERITY: medium]
- **File:** `SwipeSortTests/SwipeSessionModelTests.swift:49` (`swipeKeepAdvances`)
- **What:** `swipeKeep()` delegates entirely to `swipeFavorite()` (line 78–79), which calls `library.setFavorite(..., isFavorite: true)` and records `.keep`. The existing test asserts `queue.decisions[0] == .keep(firstId)` but never asserts that `mock.favoriteState[firstId] == true`. A future refactor separating keep (no favorite) from swipeFavorite (sets favorite) would break existing tests that currently assert `.keep` but silently pass because `setFavorite` is not checked.
- **Why it matters / failure scenario:** If the keep/favorite distinction is ever split (a planned feature per `docs/RESEARCH.md`), no test today pins the contract that "swipeKeep always marks as favorite." The unchecked `setFavorite` call could be dropped without any test failure.
- **Suggested fix direction:** Add an assertion in `swipeKeepAdvances` (and the `SettingsIntegrationTests` mode tests) that `mock.favoriteState[firstId] == true` after `swipeKeep()`.
- **Verified:** pending

### F13 — `moveToAlbum` undo symmetry: `removeAssetsFromAlbum` vs `moveAssets` path not tested against both nil/non-nil `fromAlbumId` [SEVERITY: medium]
- **File:** `SwipeSortTests/AlbumMoveTests.swift` (no undo test for either path)
- **What:** `SwipeSessionModel.undo()` follows two different code paths depending on whether the original `fromAlbumId` was nil (calls `removeAssetsFromAlbum`) or non-nil (calls `moveAssets` with reversed source/dest). Neither path has a dedicated undo test in `AlbumMoveTests`.
- **Why it matters / failure scenario:** A refactor that swaps the two branches (nil vs. non-nil) would not be caught by any existing test. The `SessionResumeTests.undoRemovesDecision` test covers `.delete` undo only, not `.moveToAlbum` undo.
- **Suggested fix direction:** Add two undo tests to `AlbumMoveTests`: one starting from `sourceAlbumId: nil` (expects `removeAssetsFromAlbum` called on the destination album) and one from `sourceAlbumId: "src"` (expects `moveAssets` called with `from: "fam", to: "src"`). Assert `mock.lastMoves` or add a `lastRemoveCalls` tracking property.
- **Verified:** pending

### F14 — `WindowedThumbnailCacheTests` does not test the `total == 0` boundary [SEVERITY: low]
- **File:** `SwipeSortTests/WindowedThumbnailCacheTests.swift` (no zero-total test)
- **What:** `WindowedThumbnailCache.slide(to:total:)` is called with `total: 20` in every test but never with `total: 0` (the empty library case) or `total: 1` (single asset). No assertion verifies that a `total: 0` call results in zero `startCachingCalls`.
- **Why it matters / failure scenario:** An empty library passes `total: 0` from `SwipeStackView` line 91. If `slide(to:total:)` computes a window range on `0..<0` incorrectly (e.g., `(0..<0).clamped(to: 0..<0)` is fine but a subtraction to compute `behind` could underflow to a huge Range on unchecked subtraction), `startCachingThumbnails` might be called with garbage indices.
- **Suggested fix direction:** Add a test: `slide(to: 0, total: 0)` and assert `mock.startCachingCalls.isEmpty`.
- **Verified:** pending

### F15 — Orientation change not tested; `cardPixelSize` is fixed at init and never updated [SEVERITY: low]
- **File:** `SwipeSortTests/` (no orientation test)
- **What:** `SwipeStackView.init` captures `cardPixelSize` as a constant (400×600 points→pixels, line 47) and passes it to both `SwipeSessionModel` and `WindowedThumbnailCache`. No test verifies that the cache or session correctly handles a `targetSize` change if orientation changes (or if the view is presented on iPad in landscape).
- **Why it matters / failure scenario:** On iPad or after orientation change, cached thumbnail sizes mismatch the displayed cell size, causing blurry thumbnails. The mismatch is silent — no test catches it.
- **Suggested fix direction:** Note the architectural gap (fixed size at init) as a finding; add a unit test that constructs a `SwipeSessionModel` with a portrait size, then checks that `WindowedThumbnailCache` was initialized with the same size. A future fix would pass a `GeometryReader`-derived size.
- **Verified:** pending

### F16 — `SwipeSortUITestsLaunchTests` is a Xcode template stub with no assertions [SEVERITY: low]
- **File:** `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift:21`
- **What:** `testLaunch()` only takes a screenshot and adds it as an attachment; it performs no assertions. The test always passes regardless of whether the app crashes on launch.
- **Why it matters / failure scenario:** A crash at startup would not be caught by the test suite's CI gate because the only launch test is effectively a no-op assertion-wise.
- **Suggested fix direction:** Add at minimum `XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))` and an assertion that the root navigation bar exists, replacing the screenshot-only approach.
- **Verified:** pending

### F17 — `BulkDeleteTests` applies a filter but `MockPhotoLibrary` ignores the filter predicate [SEVERITY: low]
- **File:** `SwipeSortTests/BulkDeleteTests.swift:14`
- **What:** `deleteAllSubmitsBatch` calls `mock.applyFilter(filter)` with `mediaType: .screenshotsOnly` but the mock's `applyFilter` implementation only stores the filter; `assetIdentifier(at:)` always returns `"mock-asset-N"` regardless of the filter. The test then asserts on all 5 identifiers as if the filter applied. The test is asserting the mock's own behavior, not the filter-then-delete integration.
- **Why it matters / failure scenario:** The test creates a false sense of security that filtered bulk delete sends only matching identifiers. A regression in the real `PhotoKitLibrary`'s `applyFilter` → `ensureFetchResult` → predicate chain would not be caught because the mock silently bypasses predicate evaluation.
- **Suggested fix direction:** Either (a) make `MockPhotoLibrary` apply simple in-memory filtering based on `scriptedFilteredCount` (which it partly does, but `assetIdentifier(at:)` still uses the raw range) so the test truly exercises the filter scope, or (b) document the test as "verifies batch submission count, not filter predicate" and add a separate test for predicate logic using `SwipeFilter.nsPredicate()`.
- **Verified:** pending

### F18 — No test for `swipePrev` when all prior photos are decided (queue full) [SEVERITY: low]
- **File:** `SwipeSortTests/SwipeSessionModelTests.swift:114` (`swipePrevSkipsDecided`)
- **What:** `swipePrevSkipsDecided` tests that `swipePrev` skips a single decided photo and lands on an undecided one. No test covers the case where *all* prior photos are decided, in which case `swipePrev` should be a no-op (the `guard let found = targetIndex` in line 138 returns early). This edge case is structurally covered by the guard but has no test pinning it.
- **Why it matters / failure scenario:** If a refactor changes the `guard` to an assertion, or mistakenly sets `currentIndex = 0` instead of performing no-op, the user is navigated to a wrong position. The absence of a test means this can silently regress.
- **Suggested fix direction:** Add a test: 3-asset library, decide all 3, call `swipePrev()`, assert `currentIndex` is unchanged.
- **Verified:** pending

### F19 — `SettingsIntegrationTests` does not test the `down` direction in Mode 2 (`rightDeleteLeftKeep`) [SEVERITY: low]
- **File:** `SwipeSortTests/SettingsIntegrationTests.swift:49`
- **What:** `mode2RightLeft` tests right (delete) and left (favorite) but never tests down (which should call `swipePrev`). Similarly, `mode1UpDown` tests up (delete) and down (favorite) but not right (which should call `swipePrev`). The `swipePrev` gesture direction for each mode is untested at the integration level.
- **Why it matters / failure scenario:** A future swap of `.down` and `.right` dispatch in `SwipeSessionModel.swipe(_:using:)` for Mode 2 would not be caught by any `SettingsIntegrationTests` test.
- **Suggested fix direction:** Add `mode1RightPrev` and `mode2DownPrev` tests asserting `currentIndex` decreases (or stays 0 if at the start) and the queue is unchanged.
- **Verified:** pending

### F20 — `removeFromDeletionQueue` (individual dequeue from review sheet) has no unit test [SEVERITY: low]
- **File:** `SwipeSortTests/` (no test for this method)
- **What:** `SwipeSessionModel.removeFromDeletionQueue(_:)` (line 223) calls `queue.removeDecision(for:)` and is exercised in `SwipeDecisionQueueTests.removeDecisionEdgeCases`. However, there is no test for `SwipeSessionModel.removeFromDeletionQueue` itself — specifically, that `pendingDeletions` is updated after the call, and that `totalPendingCount` decrements.
- **Why it matters / failure scenario:** `ReviewCommitView` (the pre-commit review sheet) calls this method to let users dequeue individual photos. If the computed `pendingDeletions` property regresses (e.g., stops deduplicating), dequeuing from the review sheet would show a stale count in the UI, and the commit would still send the dequeued identifier.
- **Suggested fix direction:** Add a test: start session, swipe 3 deletes, call `removeFromDeletionQueue` on the middle one, assert `pendingDeletions.count == 2` and the middle identifier is absent.
- **Verified:** pending
