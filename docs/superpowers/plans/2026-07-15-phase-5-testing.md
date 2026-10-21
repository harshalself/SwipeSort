# Phase 5 — Testing scaffolding Implementation Plan

> **For agentic workers:** This plan will be executed inline by the main session (mechanical test additions) with an adversarial whole-branch review at the end. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the 15 verified testing gaps from `docs/reviews/2026-07-13/phase-5-working-set.md` — add regression tests for undo failure paths, mid-session library changes, auth revocation, iCloud thumbnail failure, filter changes, concurrent swipes, Mode 2 UI coverage, empty-library swipe deck, and 6 additional low-severity gaps.

**Architecture:** Extend `MockPhotoLibrary` with 4 new scripting hooks (`nextRemoveResult`, `nextThumbnailResult`, `setCurrentAuthorization`, sparse thumbnail progressive-delivery mode). Add ~15 new unit tests across 8 test files. Add 2 UI tests and 1 launch-test hardening. No production code changes except mock hooks and any test-only accessors.

**Tech Stack:** Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) for unit tests; XCTest for UI tests; `@testable import SwipeSort`.

**Working set:** [`docs/reviews/2026-07-13/phase-5-working-set.md`](../../reviews/2026-07-13/phase-5-working-set.md)

---

## Global Constraints

- **Swift Testing for unit tests, XCTest for UI tests.** Every new file under `SwipeSortTests/` uses `import Testing` and `@Suite`/`@Test`/`#expect`. Every new file under `SwipeSortUITests/` uses `import XCTest` and `XCTAssert…`. Never mix.
- **@MainActor isolation.** Any test suite that touches `SwipeSessionModel` or `MockPhotoLibrary` must annotate the `struct` declaration with `@MainActor` (both types are `@MainActor`-isolated after Phase 2). Do not annotate individual test methods — annotate the struct.
- **Backwards-compatible mock hooks.** Any new stored property on `MockPhotoLibrary` must default to a value that preserves the existing behavior of every current test. New scripting slots should be `Optional` with `nil` = "use default behavior" and consumed-once semantics where the phase-5 test's scripted value would otherwise leak to unrelated tests.
- **Test-only phase, no production changes.** Do not add production behavior. Where a finding demands production-level fixing (e.g., F5 auth revocation, F10 filter change mid-session), the phase-5 test asserts the CURRENT behavior and includes a `// PRODUCTION GAP:` comment noting the unresolved issue. Those production gaps are logged for a future phase.
- **Explicit state assertions.** Every new test must fail obviously if the production code regresses. Prefer `#expect(model.currentIndex == 2)` and `#expect(model.phase == .ready)` over shallow "did not crash" pins.
- **Concurrent-swipe test (F3): `async let`, not `Task.detached`.** `SwipeSessionModel` is `@MainActor`; from an `async` test function on a `@MainActor` suite `async let` inherits the main-actor context and both calls serialise cooperatively on the main actor. Using `Task.detached` would break the isolation contract and give a false pin.
- **Human-driven target membership.** Every new test file must be flagged at the end of its task with a `⚠️ Human: add <path> to the SwipeSortTests (or SwipeSortUITests) Xcode target` line. Xcode target membership can only be edited through Xcode; the executor cannot land the file into the target from the CLI.
- **UI tests must reuse existing launch arguments.** Do NOT introduce new launch arguments (`--ui-testing`, `--ui-testing-empty`, `--ui-testing-denied`, `--ui-testing-single-photo` already exist and cover all needed scenarios). If a UI test needs Mode 2, drive it through the Settings screen with real navigation, not a launch-arg shortcut.
- **`SwipeSortApp.swift` correction.** The plan header references `SwipeSort/App/SwipeSortApp.swift`, but the real file lives at `SwipeSort/SwipeSortApp.swift` and the `--ui-testing*` flags are handled inside `SwipeSort/Features/MainTabView.swift`. All four flags (`--ui-testing`, `--ui-testing-empty`, `--ui-testing-denied`, `--ui-testing-single-photo`) are already wired.
- **No swift/xcodebuild in this workspace.** Every "Build" and "Test" step is a logical verification; the human runs them in Xcode.
- **Task batching.** Task 1 (mock hooks) MUST land before Tasks 2, 6, 7. Tasks 2–14 (unit tests) are mechanical and may be batched into a single implementer invocation once Task 1 is done. Tasks 15–17 (UI tests) require a separate dispatch — they need Xcode UI-driver runs to verify the accessibility paths.

---

## Task ordering rationale

1. **Task 1 (mock hooks)** — Adds `nextRemoveResult`, `nextThumbnailResult`, `setCurrentAuthorization(_:)`. Foundation for Tasks 2 (F1), 6 (F5), 7 (F9). Land first.
2. **Task 2 (F1)** — Undo-remove failure. Needs Task 1's `nextRemoveResult`.
3. **Task 3 (F2)** — Undo across `.finished` → `.ready`. Pure model test, no hooks required.
4. **Task 4 (F3)** — Concurrent swipe. Pure model test, no hooks required.
5. **Task 5 (F4)** — Mid-session `refreshFetchResult`. Pure model test.
6. **Task 6 (F5)** — Auth revocation mid-session. Needs Task 1's `setCurrentAuthorization`.
7. **Task 7 (F9)** — Nil / degraded thumbnail. Needs Task 1's `nextThumbnailResult`.
8. **Task 8 (F10)** — Mid-session filter change. Pure model test.
9. **Task 9 (F13)** — Undo symmetry (nil vs non-nil source). Pure model test.
10. **Task 10 (F14)** — Zero-total window. Pure cache test.
11. **Task 11 (F17)** — Bulk-delete filter fidelity. Uses existing `scriptedFilteredCount`.
12. **Task 12 (F18)** — `swipePrev` at index 0 no-op. Pure model test.
13. **Task 13 (F19)** — Mode `swipePrev` direction dispatches. Pure model test.
14. **Task 14 (F20)** — `removeFromDeletionQueue`. Pure model test.
15. **Task 15 (F7)** — Mode 2 UI test (real Settings navigation).
16. **Task 16 (F8)** — Empty-library grid-tap absence UI test.
17. **Task 17 (F16)** — Launch-test hardening.

---

## Task 1 — MockPhotoLibrary scripting hooks (foundation)

**Files:**
- Modify: `SwipeSort/Core/MockPhotoLibrary.swift`
- Test: `SwipeSortTests/MockPhotoLibraryScriptingTests.swift` (new file — sanity checks for the new hooks)

**Interfaces produced:**
- `var nextRemoveResult: CommitResult?` — when set, `removeAssetsFromAlbum` returns it instead of `.success`. Consumed-once (reset to `nil` after each call so a scripted `.failed` cannot leak to a subsequent test).
- `var nextThumbnailResult: AssetThumbnail??` — double-optional. Outer `nil` = default behavior (synthesise placeholder). Outer `.some(nil)` = return `nil`. Outer `.some(.some(x))` = return `x`. Consumed-once: reset to `nil` after each call.
- `func setCurrentAuthorization(_:)` — exposes a mid-flight setter for the previously-private `currentAuth`. Also useful for orchestrating auth-revocation tests without a full `MockPhotoLibrary` rebuild.

**Backwards compatibility:** All existing tests use `mock.applyFilter`, `mock.commitDeletions`, `mock.thumbnail(for:)`, and `mock.moveAssets` without touching any of the three new slots. Defaults (`nil`, `nil`, method-only) leave every existing test's behavior unchanged. Verified by re-running the full test suite after Task 1.

- [ ] **Step 1: Add `nextRemoveResult` and update `removeAssetsFromAlbum`**

In `SwipeSort/Core/MockPhotoLibrary.swift`, after the existing `nextMoveResult` declaration around line 40, insert:

```swift
    /// When set, `removeAssetsFromAlbum` returns this result instead of the default
    /// `.success`. Consumed once — reset to `nil` after each call so a scripted
    /// failure cannot leak into subsequent tests through a shared mock.
    var nextRemoveResult: CommitResult?
```

Replace the existing `removeAssetsFromAlbum` implementation (lines 150–153):

```swift
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        lastRemoves.append((albumId: albumId, ids: ids))
        return .success(affectedCount: ids.count)
    }
```

With:

```swift
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        lastRemoves.append((albumId: albumId, ids: ids))
        if let scripted = nextRemoveResult {
            nextRemoveResult = nil    // consumed-once
            return scripted
        }
        return .success(affectedCount: ids.count)
    }
```

- [ ] **Step 2: Add `nextThumbnailResult` and update `thumbnail(for:targetSize:)`**

In `SwipeSort/Core/MockPhotoLibrary.swift`, after the existing `scriptedMediaKinds` declaration around line 47, insert:

```swift
    /// When set, the next call to `thumbnail(for:targetSize:)` returns this value
    /// instead of the default placeholder. Double-optional:
    ///   - `nil` outer: default behavior (synthesise a placeholder — existing tests).
    ///   - `.some(nil)`: return `nil` (F9 nil-thumbnail regression scenario).
    ///   - `.some(.some(x))`: return `x` (F9 degraded-thumbnail scenario).
    /// Consumed once — reset to `nil` after the call so subsequent thumbnail fetches
    /// (e.g., next/prev pre-fetch inside the same `loadCurrent()`) use the default path.
    var nextThumbnailResult: AssetThumbnail??
```

Replace the existing `thumbnail(for:targetSize:)` implementation (lines 105–114):

```swift
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? {
        let hash = abs(identifier.rawValue.hashValue) % 360
        let color = UIColor(hue: CGFloat(hash) / 360.0, saturation: 0.6, brightness: 0.9, alpha: 1.0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return AssetThumbnail(identifier: identifier, image: image, isDegraded: false)
    }
```

With:

```swift
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail? {
        if let scripted = nextThumbnailResult {
            nextThumbnailResult = nil    // consumed-once
            return scripted              // may itself be nil (F9)
        }
        let hash = abs(identifier.rawValue.hashValue) % 360
        let color = UIColor(hue: CGFloat(hash) / 360.0, saturation: 0.6, brightness: 0.9, alpha: 1.0)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return AssetThumbnail(identifier: identifier, image: image, isDegraded: false)
    }
```

- [ ] **Step 3: Add `setCurrentAuthorization(_:)`**

In `SwipeSort/Core/MockPhotoLibrary.swift`, after `requestAuthorization()` (ends around line 83), insert:

```swift
    /// Overwrites the current authorization state used by `currentAuthorization()`.
    ///
    /// Test-only mutation hook for F5 (auth revocation mid-session). Distinct from
    /// `nextAuthorizationDecision`, which is only honored by `requestAuthorization()`.
    /// The session model reads `currentAuthorization()` at startup, so switching
    /// this value after `phase == .ready` pins the model's mid-session revocation
    /// behavior.
    func setCurrentAuthorization(_ auth: PhotoLibraryAuthorization) {
        currentAuth = auth
    }
```

- [ ] **Step 4: Write the mock-scripting sanity test file**

Create `SwipeSortTests/MockPhotoLibraryScriptingTests.swift`:

```swift
import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("MockPhotoLibrary scripting hooks")
struct MockPhotoLibraryScriptingTests {

    @Test("nextRemoveResult overrides success once, then reverts to default")
    func nextRemoveResultConsumedOnce() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        mock.nextRemoveResult = .failed(reason: "smart album")

        let first  = await mock.removeAssetsFromAlbum([AssetIdentifier("x")], albumId: "a")
        let second = await mock.removeAssetsFromAlbum([AssetIdentifier("x")], albumId: "a")

        #expect(first  == .failed(reason: "smart album"))
        #expect(second == .success(affectedCount: 1),
            "second call must revert to default success — hook is consumed-once")
    }

    @Test("nextThumbnailResult .some(nil) makes thumbnail(for:) return nil once")
    func nextThumbnailResultNil() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        mock.nextThumbnailResult = .some(nil)

        let first  = await mock.thumbnail(for: AssetIdentifier("mock-asset-0"),
                                          targetSize: CGSize(width: 1, height: 1))
        let second = await mock.thumbnail(for: AssetIdentifier("mock-asset-1"),
                                          targetSize: CGSize(width: 1, height: 1))

        #expect(first == nil)
        #expect(second != nil, "second call must revert to default placeholder")
    }

    @Test("nextThumbnailResult with degraded thumbnail flows through once")
    func nextThumbnailResultDegraded() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let degraded = AssetThumbnail(
            identifier: AssetIdentifier("mock-asset-0"),
            image: img,
            isDegraded: true
        )
        mock.nextThumbnailResult = .some(degraded)

        let result = await mock.thumbnail(for: AssetIdentifier("mock-asset-0"),
                                          targetSize: CGSize(width: 1, height: 1))
        #expect(result?.isDegraded == true)
    }

    @Test("setCurrentAuthorization overwrites the stored authorization")
    func setCurrentAuthorizationOverwrites() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        #expect(await mock.currentAuthorization() == .authorized)

        mock.setCurrentAuthorization(.denied)
        #expect(await mock.currentAuthorization() == .denied)
    }
}
```

- [ ] **Step 5: Build (logical verify)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `AssetThumbnail??` is a valid Swift double-optional. `setCurrentAuthorization(_:)` mutates a `private var` on the same `@MainActor`-isolated type — no isolation errors.

- [ ] **Step 6: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: **all existing tests still PASS**, plus the four new `MockPhotoLibraryScriptingTests` PASS. If any existing test regresses, the new hook's default is not truly transparent — investigate before proceeding.

- [ ] **Step 7: Commit**

```
Report line: "phase-5/task-1: added nextRemoveResult / nextThumbnailResult / setCurrentAuthorization scripting hooks to MockPhotoLibrary with consumed-once defaults; sanity tests confirm backwards-compat"
```

⚠️ **Human: add `SwipeSortTests/MockPhotoLibraryScriptingTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 2 — F1: undo of moveToAlbum (nil source) surfaces removeAssetsFromAlbum failure

**Files:**
- Modify: `SwipeSortTests/AlbumMoveTests.swift` (add one test)

**Interfaces consumed:** `mock.nextRemoveResult` (from Task 1); `SwipeSessionModel.undo()`; `mock.lastRemoves`.

- [ ] **Step 1: Write the regression test**

In `SwipeSortTests/AlbumMoveTests.swift`, at the end of the `AlbumMoveTests` struct (after `func createNewAlbumAndMoveBatch()`), add:

```swift
    @Test("undo of moveToAlbum from nil source records the remove call even when it fails")
    func undoMoveFromNilSourceHandlesRemoveFailure() async {
        // PRODUCTION GAP: SwipeSessionModel.undo() at SwipeSessionModel.swift:282–286
        // logs the .failed result but does not roll back the popped decision or surface
        // an error to the caller. This test pins the CURRENT contract — the queue is
        // emptied by undoLast() regardless of whether the physical remove succeeds.
        // A future phase should route the failure through a session-level warning.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])

        // Ensure dry-run is OFF for this test: undo() skips the remove entirely in
        // dry-run mode (SwipeSessionModel.swift:281), which would bypass the very
        // path this test is trying to exercise.
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(m.queue.decisions.count == 1)

        // Script the removeAssetsFromAlbum call to fail.
        mock.nextRemoveResult = .failed(reason: "smart album cannot removeContent")

        // Perform the undo — model logs the failure and continues.
        let undone = await m.undo()

        // The .moveToAlbum decision was popped from the queue (undoLast fires unconditionally).
        #expect(m.queue.decisions.isEmpty)
        if case .moveToAlbum(let id, _, _)? = undone {
            #expect(id == firstId)
        } else {
            Issue.record("expected the popped decision to be .moveToAlbum")
        }
        // The remove call was actually attempted (mock recorded it) — this pins the
        // undo path against a refactor that would silently skip the remove.
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "fam")
        #expect(mock.lastRemoves[0].ids == [firstId])
        // Phase transitions cleanly regardless of the remove result.
        #expect(m.phase == .ready)
    }
```

- [ ] **Step 2: Run the test**

In Xcode: Product → Test → filter to `AlbumMoveTests/undoMoveFromNilSourceHandlesRemoveFailure`.

Expected: **PASS**. The test asserts the current contract (queue popped, remove attempted, phase reverts).

- [ ] **Step 3: Commit**

```
Report line: "phase-5/task-2: added undoMoveFromNilSourceHandlesRemoveFailure to AlbumMoveTests — pins current undo-remove failure contract (F1)"
```

---

## Task 3 — F2: undo across `.finished` → `.ready` transition

**Files:**
- Modify: `SwipeSortTests/SessionResumeTests.swift` (add one test)

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SessionResumeTests.swift`, at the end of the `SessionResumeTests` struct:

```swift
    @Test("undo from .finished restores .ready phase and reloads currentThumbnail")
    func undoFromFinishedRestoresReadyPhase() async {
        // 2-asset session; swipe both to reach .finished; then undo.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        await m.swipeKeep()   // 0 → decided
        await m.swipeKeep()   // 1 → decided → phase transitions to .finished
        #expect(m.phase == .finished)
        #expect(m.currentThumbnail == nil,
            "after finishing, the current thumbnail must be cleared")

        // Undo should transition back to .ready AND repopulate currentThumbnail.
        await m.undo()
        #expect(m.phase == .ready,
            "undo from .finished must transition phase back to .ready")
        #expect(m.currentThumbnail != nil,
            "undo from .finished must reload currentThumbnail so the deck is renderable")
        #expect(m.currentIndex == 1,
            "undo must position the cursor on the asset whose decision was popped")
    }
```

- [ ] **Step 2: Run & commit**

Run `SessionResumeTests/undoFromFinishedRestoresReadyPhase`. Expected: **PASS**.

```
Report line: "phase-5/task-3: added undoFromFinishedRestoresReadyPhase — pins .finished → .ready transition via undo (F2)"
```

---

## Task 4 — F3: concurrent swipe regression test

**Files:**
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` (add one test)

**Rationale:** `SwipeSessionModel` is `@MainActor`. `async let` from a `@MainActor` test function inherits the main-actor context, so both `swipe*()` calls serialise cooperatively on the main actor. The test pins that two swipes fired without an `await` between them do not corrupt state — exactly 2 unique identifiers must appear in the queue.

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`, at the end of the `SwipeSessionModelTests` struct (after `configureTargetSize`):

```swift
    @Test("two swipes dispatched concurrently record exactly 2 unique identifiers")
    func concurrentSwipesDoNotCorruptQueue() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.totalCount == 2)

        // Dispatch both swipes with `async let` — inherits @MainActor context.
        // Task.detached would break isolation; async let preserves it.
        async let first: () = m.swipeDelete()
        async let second: () = m.swipeKeep()
        _ = await first
        _ = await second

        // Exactly 2 decisions, one per asset. No duplicates, no missing entries.
        #expect(m.queue.decisions.count == 2,
            "exactly 2 decisions must be recorded regardless of dispatch order")
        let uniqueIds = Set(m.queue.decisions.map(\.identifier))
        #expect(uniqueIds.count == 2,
            "both decisions must target distinct assets — no double-execute on the same id")
        // currentIndex must be exactly 2 (both advance() calls landed).
        #expect(m.currentIndex == 2)
        #expect(m.phase == .finished,
            "after both swipes on a 2-asset library, phase must be .finished")
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSessionModelTests/concurrentSwipesDoNotCorruptQueue`. Expected: **PASS**.

```
Report line: "phase-5/task-4: added concurrentSwipesDoNotCorruptQueue — pins @MainActor serialisation of concurrent swipes (F3)"
```

---

## Task 5 — F4: mid-session library-change (refreshFetchResult) test

**Files:**
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` (add one test)

**Note:** `MockPhotoLibrary.refreshFetchResult()` is currently a documented no-op. The test asserts the CURRENT behavior — that a refresh mid-session does not corrupt the session's advance path. A production fix (re-validating `currentIndex` after a refresh) is out of scope for this phase.

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`, at the end of the `SwipeSessionModelTests` struct:

```swift
    @Test("refreshFetchResult mid-session does not corrupt subsequent swipe recording")
    func midSessionLibraryChangeDoesNotCorruptSwipe() async {
        // PRODUCTION GAP: SwipeSessionModel does not re-validate currentIndex after
        // a PhotoLibraryChangePublisher.didChangeNotification. This test pins the
        // CURRENT behavior — a refresh with a stable asset count preserves cursor
        // semantics — but the real risk (an asset shifting under the cursor) is
        // untested because MockPhotoLibrary.refreshFetchResult() is a no-op.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.phase == .ready)

        // Simulate a library-change notification mid-session.
        await mock.refreshFetchResult()

        // The subsequent swipe must still record the current asset's identifier —
        // if the model were re-fetching state on every advance it could otherwise
        // record a stale or wrong identifier.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeKeep()

        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        #expect(m.phase == .ready,
            "phase must remain .ready — a mid-session refresh must not force .finished or .loading")
        #expect(m.currentIndex == 1)
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSessionModelTests/midSessionLibraryChangeDoesNotCorruptSwipe`. Expected: **PASS**.

```
Report line: "phase-5/task-5: added midSessionLibraryChangeDoesNotCorruptSwipe — pins current refresh-mid-session contract; flags production gap (F4)"
```

---

## Task 6 — F5: auth revocation mid-session

**Files:**
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` (add one test)

**Note:** `SwipeSessionModel.start()` reads authorization once at startup; no downstream method re-checks. This test pins the CURRENT behavior — the session continues advancing even after auth is revoked mid-flight. A production fix would need to route `.denied` back to the UI mid-session.

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`, at the end of the `SwipeSessionModelTests` struct:

```swift
    @Test("auth revocation after .ready does not force phase change (current behavior)")
    func authRevocationMidSessionCurrentBehavior() async {
        // PRODUCTION GAP: SwipeSessionModel checks authorization only in start()
        // (SwipeSessionModel.swift:86–105). After phase == .ready, revoking access
        // is silently ignored — the model keeps returning currentThumbnails from the
        // mock's cached fetch state. This test asserts that current behavior so a
        // future production fix (routing .denied through a mid-session watcher) has
        // a regression pin to replace.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.phase == .ready)

        // Revoke access mid-session.
        mock.setCurrentAuthorization(.denied)

        // The model does not observe this; the next swipe still records normally.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeKeep()

        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        // Phase remains .ready — the model has no mid-session revocation handler.
        #expect(m.phase == .ready)
        // But currentAuthorization() now reports .denied — verify the mock hook worked.
        let auth = await mock.currentAuthorization()
        #expect(auth == .denied)
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSessionModelTests/authRevocationMidSessionCurrentBehavior`. Expected: **PASS**.

```
Report line: "phase-5/task-6: added authRevocationMidSessionCurrentBehavior — pins current mid-session auth-revocation contract; flags production gap (F5)"
```

---

## Task 7 — F9: nil-thumbnail and degraded-delivery tests

**Files:**
- Create: `SwipeSortTests/ThumbnailDeliveryTests.swift` (new file — dedicated suite for thumbnail-boundary contracts)

**Interfaces consumed:** `mock.nextThumbnailResult` (from Task 1); `SwipeSessionModel.currentThumbnail`; `AssetThumbnail.isDegraded`.

- [ ] **Step 1: Create the test file**

Create `SwipeSortTests/ThumbnailDeliveryTests.swift`:

```swift
import Testing
import UIKit
@testable import SwipeSort

@MainActor
@Suite("Thumbnail delivery boundary cases")
struct ThumbnailDeliveryTests {

    private let targetSize = CGSize(width: 1, height: 1)

    @Test("nil thumbnail on start leaves currentThumbnail nil but phase reaches .ready")
    func nilThumbnailOnStart() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
        // Script the FIRST thumbnail fetch (currentThumbnail load) to return nil.
        // Next/prev pre-fetches inside the same loadCurrent() consume the default path
        // because nextThumbnailResult is consumed-once.
        mock.nextThumbnailResult = .some(nil)

        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        // No crash. Phase reached .ready (loadInitial sets .ready after loadCurrent).
        #expect(m.phase == .ready,
            "session must still reach .ready even when the first thumbnail is nil")
        #expect(m.currentThumbnail == nil,
            "nil scripted thumbnail must be assigned directly with no fallback synthesis")
        #expect(m.totalCount == 2)
        #expect(m.currentIndex == 0)
    }

    @Test("degraded thumbnail flows through with isDegraded == true")
    func degradedThumbnailOnStart() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let img = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let degraded = AssetThumbnail(
            identifier: AssetIdentifier("mock-asset-0"),
            image: img,
            isDegraded: true
        )
        mock.nextThumbnailResult = .some(degraded)

        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        #expect(m.currentThumbnail?.isDegraded == true,
            "the degraded flag must be preserved end-to-end from the mock to the model")
        #expect(m.currentThumbnail?.identifier.rawValue == "mock-asset-0")
        #expect(m.phase == .ready)
    }
}
```

- [ ] **Step 2: Run & commit**

Run `ThumbnailDeliveryTests`. Expected: both tests **PASS**.

```
Report line: "phase-5/task-7: added ThumbnailDeliveryTests (nilThumbnailOnStart, degradedThumbnailOnStart) — pins nil / degraded thumbnail boundary contracts (F9)"
```

⚠️ **Human: add `SwipeSortTests/ThumbnailDeliveryTests.swift` to the SwipeSortTests Xcode target.**

---

## Task 8 — F10: mid-session filter change

**Files:**
- Modify: `SwipeSortTests/ApplyFilterRefreshTests.swift` (add one test)

**Note:** `PhotoLibraryReadProviding.applyFilter` doc says "MUST be called before `SwipeSessionModel.start()`". The mock's `applyFilter` records the filter and is otherwise a no-op. The test pins CURRENT behavior — a mid-session `applyFilter` call does not restart the session or corrupt `currentIndex`. A production enforcement (precondition or session reset) is out of scope.

- [ ] **Step 1: Write the test**

Append to `SwipeSortTests/ApplyFilterRefreshTests.swift`, inside the `ApplyFilterRefreshTests` struct:

```swift
    @Test("applyFilter mid-session does not reset the cursor or corrupt subsequent swipe")
    func applyFilterMidSessionDoesNotResetCursor() async {
        // PRODUCTION GAP: PhotoLibraryReadProviding.applyFilter is documented as
        // "before start() only" but no runtime guard enforces it. This test pins
        // the current mock behavior — applying a filter mid-session records it but
        // does not corrupt cursor state. If production ever adds a precondition or
        // a session-reset on mid-session filter change, this test must be updated.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 1, height: 1))
        await m.start()
        #expect(m.currentIndex == 0)
        #expect(m.phase == .ready)

        // Mid-session filter change — the mock records the filter but does not
        // rebuild the fetch cursor. currentIndex is preserved.
        var newFilter = SwipeFilter.unfiltered
        newFilter.mediaType = .videosOnly
        await mock.applyFilter(newFilter)
        #expect(mock.appliedFilter == newFilter,
            "mock must have recorded the mid-session filter change")

        // Subsequent swipe advances normally — the current asset id is still valid.
        let firstId = m.currentThumbnail!.identifier
        await m.swipeKeep()
        #expect(m.queue.decisions.count == 1)
        #expect(m.queue.decisions[0] == .keep(firstId))
        #expect(m.currentIndex == 1)
        #expect(m.phase == .ready)
    }
```

- [ ] **Step 2: Run & commit**

Run `ApplyFilterRefreshTests/applyFilterMidSessionDoesNotResetCursor`. Expected: **PASS**.

```
Report line: "phase-5/task-8: added applyFilterMidSessionDoesNotResetCursor to ApplyFilterRefreshTests — pins current mid-session filter-change contract; flags production gap (F10)"
```

---

## Task 9 — F13: undo symmetry (nil vs non-nil source album)

**Files:**
- Modify: `SwipeSortTests/AlbumMoveTests.swift` (add two tests)

**Interfaces consumed:** `mock.lastMoves`, `mock.lastRemoves`, `SwipeSessionModel.undo()`.

- [ ] **Step 1: Write both tests**

Add to `SwipeSortTests/AlbumMoveTests.swift` at the end of the `AlbumMoveTests` struct:

```swift
    @Test("undo of moveToAlbum from nil source calls removeAssetsFromAlbum on the destination")
    func undoMoveFromNilSourceCallsRemove() async {
        // Dry-run must be OFF for the remove path to execute (SwipeSessionModel.swift:281).
        let originalDryRun = DryRunMode.isEnabled
        DryRunMode.setEnabled(false)
        defer { DryRunMode.setEnabled(originalDryRun) }

        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: nil, targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastRemoves.isEmpty)

        await m.undo()

        // Undo must have called removeAssetsFromAlbum on "fam" for firstId.
        #expect(mock.lastRemoves.count == 1)
        #expect(mock.lastRemoves[0].albumId == "fam")
        #expect(mock.lastRemoves[0].ids == [firstId])
        // The reversed move path (moveAssets) must NOT have fired.
        #expect(mock.lastMoves.count == 1, "no reversed moveAssets call for nil-source undo")
        #expect(m.queue.decisions.isEmpty)
    }

    @Test("undo of moveToAlbum from a source album calls moveAssets reversed (dest → source)")
    func undoMoveFromSourceCallsReversedMove() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        mock.seedAlbums([
            UserAlbum(id: "src", title: "Inbox",  assetCount: 3, canAdd: true),
            UserAlbum(id: "fam", title: "Family", assetCount: 0, canAdd: true)
        ])
        let m = SwipeSessionModel(
            library: mock, sourceAlbumId: "src", targetSize: CGSize(width: 1, height: 1)
        )
        await m.start()
        let firstId = m.currentThumbnail!.identifier
        await m.swipeUp(intoAlbumId: "fam")
        #expect(mock.lastMoves.count == 1)
        #expect(mock.lastMoves[0].from == "src")
        #expect(mock.lastMoves[0].to == "fam")

        await m.undo()

        // Undo must have appended a REVERSED moveAssets call: from "fam" back to "src".
        #expect(mock.lastMoves.count == 2)
        #expect(mock.lastMoves[1].from == "fam")
        #expect(mock.lastMoves[1].to   == "src")
        #expect(mock.lastMoves[1].ids  == [firstId])
        // No remove call should have fired for the non-nil-source path.
        #expect(mock.lastRemoves.isEmpty)
        #expect(m.queue.decisions.isEmpty)
    }
```

- [ ] **Step 2: Run & commit**

Run both new tests. Expected: **both PASS**.

```
Report line: "phase-5/task-9: added undoMoveFromNilSourceCallsRemove and undoMoveFromSourceCallsReversedMove to AlbumMoveTests — pins undo symmetry (F13)"
```

---

## Task 10 — F14: zero-total window explicit test

**Files:**
- Modify: `SwipeSortTests/WindowedThumbnailCacheTests.swift` (add one test)

**Note:** Phase 4 added the `lower < upper` guard. F14 is CLOSED behaviorally but the explicit zero-total assertion is still missing.

- [ ] **Step 1: Write the test**

Append to `SwipeSortTests/WindowedThumbnailCacheTests.swift`, inside the `WindowedThumbnailCacheTests` struct:

```swift
    @Test("slide(to: 0, total: 0) issues no caching calls")
    func slideZeroTotalIsNoOp() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 0)
        let cache = WindowedThumbnailCache(library: mock, aheadOf: 5, behind: 2, targetSize: size)

        // Verify baseline: no calls issued yet.
        #expect(mock.startCachingCalls.isEmpty)
        #expect(mock.stopCachingCalls.isEmpty)

        // The empty-library path — SwipeStackView passes total: 0 when assetCount is 0.
        await cache.slide(to: 0, total: 0)

        #expect(mock.startCachingCalls.isEmpty,
            "empty library must trigger zero startCachingImages calls")
        #expect(mock.stopCachingCalls.isEmpty,
            "empty library must trigger zero stopCachingImages calls — no stale window to drain")
    }
```

- [ ] **Step 2: Run & commit**

Run `WindowedThumbnailCacheTests/slideZeroTotalIsNoOp`. Expected: **PASS**.

```
Report line: "phase-5/task-10: added slideZeroTotalIsNoOp to WindowedThumbnailCacheTests — explicit zero-total assertion (F14)"
```

---

## Task 11 — F17: BulkDeleteTests filter fidelity

**Files:**
- Modify: `SwipeSortTests/BulkDeleteTests.swift` (rewrite `deleteAllSubmitsBatch`)

**Rationale:** The current `deleteAllSubmitsBatch` applies a `.screenshotsOnly` filter and asserts all 5 identifiers were submitted — but the mock ignores the filter predicate. Setting `mock.scriptedFilteredCount` makes the assertion meaningful: `assetCount()` and `identifiers(in:)` both honor `effectiveCount = scriptedFilteredCount ?? count`, so the effective range narrows to the scripted count.

- [ ] **Step 1: Rewrite `deleteAllSubmitsBatch`**

In `SwipeSortTests/BulkDeleteTests.swift`, replace the existing `deleteAllSubmitsBatch` (lines 9–25):

```swift
    @Test("deleteAll submits every filtered identifier in one batch")
    func deleteAllSubmitsBatch() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        var filter = SwipeFilter.unfiltered
        filter.mediaType = .screenshotsOnly
        await mock.applyFilter(filter)

        let helper = BulkDeleteHelper(library: mock)
        let result = await helper.deleteAll()

        #expect(result == .success(affectedCount: 5))
        #expect(mock.lastCommittedDeletions.count == 5)
        // Same identifiers, in fetch order.
        #expect(mock.lastCommittedDeletions.map(\.rawValue) == [
            "mock-asset-0", "mock-asset-1", "mock-asset-2", "mock-asset-3", "mock-asset-4"
        ])
    }
```

With:

```swift
    @Test("deleteAll submits every filtered identifier in one batch (filter narrows scope)")
    func deleteAllSubmitsBatch() async {
        // F17 fix: set scriptedFilteredCount so the mock's effectiveCount reflects the
        // narrowed filter scope. Without this the mock ignored the filter predicate
        // entirely, and the test was asserting the raw library size dressed up as
        // "filter-aware" — a false-positive that would not catch a real predicate
        // regression.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
        mock.scriptedFilteredCount = 3   // filter narrows 5 → 3
        var filter = SwipeFilter.unfiltered
        filter.mediaType = .screenshotsOnly
        await mock.applyFilter(filter)

        let helper = BulkDeleteHelper(library: mock)
        let result = await helper.deleteAll()

        // The batch was scoped to the filter's effective count (3), not the raw count (5).
        #expect(result == .success(affectedCount: 3))
        #expect(mock.lastCommittedDeletions.count == 3)
        // Identifiers are the first three from the narrowed cursor, in fetch order.
        #expect(mock.lastCommittedDeletions.map(\.rawValue) == [
            "mock-asset-0", "mock-asset-1", "mock-asset-2"
        ])
    }
```

- [ ] **Step 2: Run & commit**

Run `BulkDeleteTests/deleteAllSubmitsBatch`. Expected: **PASS**.

```
Report line: "phase-5/task-11: rewrote deleteAllSubmitsBatch to set scriptedFilteredCount and assert against narrowed scope — filter fidelity (F17)"
```

---

## Task 12 — F18: swipePrev at index 0 is a no-op

**Files:**
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` (add one test)

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`, at the end of the `SwipeSessionModelTests` struct:

```swift
    @Test("swipePrev at currentIndex == 0 is a no-op (no cursor change, no queue mutation)")
    func swipePrevAtIndexZeroIsNoOp() async {
        // Pins the `guard currentIndex > 0 else { return }` at SwipeSessionModel.swift:229.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        #expect(m.currentIndex == 0)
        let firstThumb = m.currentThumbnail

        // Attempt to go back from the very first card.
        await m.swipePrev()

        #expect(m.currentIndex == 0,
            "swipePrev at index 0 must not underflow to -1 or wrap")
        #expect(m.queue.decisions.isEmpty,
            "swipePrev is navigation, not a decision — the queue must be untouched")
        #expect(m.currentThumbnail?.identifier == firstThumb?.identifier,
            "currentThumbnail must still be the first asset after a no-op swipePrev")
        #expect(m.phase == .ready)
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSessionModelTests/swipePrevAtIndexZeroIsNoOp`. Expected: **PASS**.

```
Report line: "phase-5/task-12: added swipePrevAtIndexZeroIsNoOp — pins the currentIndex == 0 guard in swipePrev() (F18)"
```

---

## Task 13 — F19: Mode `swipePrev` direction tests

**Files:**
- Modify: `SwipeSortTests/SettingsIntegrationTests.swift` (add two tests)

- [ ] **Step 1: Write both tests**

Add to `SwipeSortTests/SettingsIntegrationTests.swift`, at the end of the `SettingsIntegrationTests` struct:

```swift
    @Test("Mode 1 (upDeleteDownKeep) — right dispatches to swipePrev")
    func mode1RightPrev() async {
        // Pins the Mode 1 dispatch: SwipeSessionModel.swipe(_:using:) → .right → swipePrev.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: ts)
        await m.start()
        // Advance twice so currentIndex is 2 and swipePrev can measurably decrement.
        await m.swipeNext()
        await m.swipeNext()
        #expect(m.currentIndex == 2)

        // In Mode 1, .right is swipePrev.
        await m.swipe(.right, using: settings(mode: .upDeleteDownKeep))

        #expect(m.currentIndex == 1,
            "Mode 1 .right must call swipePrev; currentIndex should decrement by 1")
        // No decision was recorded — swipePrev is pure navigation.
        #expect(m.queue.decisions.isEmpty)
    }

    @Test("Mode 2 (rightDeleteLeftKeep) — down dispatches to swipePrev")
    func mode2DownPrev() async {
        // Pins the Mode 2 dispatch: SwipeSessionModel.swipe(_:using:) → .down → swipePrev.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: ts)
        await m.start()
        await m.swipeNext()
        await m.swipeNext()
        #expect(m.currentIndex == 2)

        // In Mode 2, .down is swipePrev.
        await m.swipe(.down, using: settings(mode: .rightDeleteLeftKeep))

        #expect(m.currentIndex == 1,
            "Mode 2 .down must call swipePrev; currentIndex should decrement by 1")
        #expect(m.queue.decisions.isEmpty)
    }
```

- [ ] **Step 2: Run & commit**

Run both new tests. Expected: **both PASS**.

```
Report line: "phase-5/task-13: added mode1RightPrev and mode2DownPrev to SettingsIntegrationTests — pins Mode 1/2 swipePrev direction dispatch (F19)"
```

---

## Task 14 — F20: removeFromDeletionQueue

**Files:**
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` (add one test)

- [ ] **Step 1: Write the test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`, at the end of the `SwipeSessionModelTests` struct:

```swift
    @Test("removeFromDeletionQueue drops a single id and preserves the rest")
    func removeFromDeletionQueueSingleId() async {
        // Pins SwipeSessionModel.removeFromDeletionQueue(_:) at SwipeSessionModel.swift:345.
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()

        let ids = [
            AssetIdentifier("mock-asset-0"),
            AssetIdentifier("mock-asset-1"),
            AssetIdentifier("mock-asset-2")
        ]
        await m.swipeDelete()
        await m.swipeDelete()
        await m.swipeDelete()
        #expect(m.pendingDeletions.count == 3)
        #expect(m.totalPendingCount == 3)

        // Remove the middle asset only.
        m.removeFromDeletionQueue(ids[1])

        #expect(m.pendingDeletions.count == 2,
            "removeFromDeletionQueue must drop exactly one entry")
        #expect(!m.pendingDeletions.contains(ids[1]),
            "the removed identifier must no longer appear in pendingDeletions")
        #expect(m.pendingDeletions.contains(ids[0]))
        #expect(m.pendingDeletions.contains(ids[2]))
        #expect(m.totalPendingCount == 2,
            "totalPendingCount must decrement in lockstep with pendingDeletions.count")
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSessionModelTests/removeFromDeletionQueueSingleId`. Expected: **PASS**.

```
Report line: "phase-5/task-14: added removeFromDeletionQueueSingleId — pins SwipeSessionModel.removeFromDeletionQueue behavior (F20)"
```

---

## Task 15 — F7: Mode 2 UI test (real Settings navigation)

**Files:**
- Modify: `SwipeSortUITests/SwipeSortUITests.swift` (add one test)

**Preflight (executor MUST do before writing the test):**
- Read `SwipeSort/Features/Settings/SettingsView.swift`. Confirm the `Picker("Gesture Mode", selection: $s.gestureMode)` uses `.pickerStyle(.navigationLink)` (currently line 31). The picker renders as a `NavigationLink` row whose accessible label is `"Gesture Mode"` and whose destination is a list of `Text(m.displayName).tag(m)` rows.
- Mode 2's `displayName` is `"Mode 2 (Right: Delete, Left: Fav)"` (see `SettingsView.swift`, private `GestureMode` extension). This is the exact string XCUI must match.
- Confirm the swipe deck exposes `SwipeCard` (line 259), `ProgressCounter` (line 182), and `PendingDeletionsButton` (line 218) — all present.

- [ ] **Step 1: Write the UI test**

Add to `SwipeSortUITests/SwipeSortUITests.swift`, after `testSettingsTabInteractions`:

```swift
    @MainActor
    func testMode2SwipeRightDeletes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]   // 6-asset mock library
        app.launch()

        // 1. Navigate to Settings.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "Settings tab must exist")
        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))

        // 2. Open the Gesture Mode picker. `.pickerStyle(.navigationLink)` renders the
        //    picker as a button/row with the label "Gesture Mode".
        let gesturePickerRow = app.buttons["Gesture Mode"]
        if !gesturePickerRow.waitForExistence(timeout: 3) {
            // Fallback: some SwiftUI versions render the row as a static-text link.
            let staticFallback = app.staticTexts["Gesture Mode"]
            XCTAssertTrue(staticFallback.waitForExistence(timeout: 2),
                "Gesture Mode row must exist on Settings screen (accessible as button or staticText)")
            staticFallback.tap()
        } else {
            gesturePickerRow.tap()
        }

        // 3. Select Mode 2. The row label is set by GestureMode.displayName in SettingsView.
        let mode2Row = app.staticTexts["Mode 2 (Right: Delete, Left: Fav)"]
        XCTAssertTrue(mode2Row.waitForExistence(timeout: 3),
            "Mode 2 row must be reachable after tapping Gesture Mode")
        mode2Row.tap()

        // 4. Navigate back to Settings.
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap() }

        // 5. Return to Recents and open the swipe deck.
        let recentsTab = app.tabBars.buttons["Recents"]
        XCTAssertTrue(recentsTab.waitForExistence(timeout: 3))
        recentsTab.tap()
        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        firstCell.tap()

        // 6. Confirm we are on the deck and the counter reads 1 of 6.
        let progressCounter = app.staticTexts["ProgressCounter"]
        XCTAssertTrue(progressCounter.waitForExistence(timeout: 5))
        XCTAssertEqual(progressCounter.label, "1 of 6")

        // 7. Swipe right — in Mode 2 this is the DELETE gesture.
        let swipeCard = app.otherElements["SwipeCard"]
        if swipeCard.waitForExistence(timeout: 3) {
            swipeCard.swipeRight()
        } else {
            app.windows.firstMatch.swipeRight()
        }

        // 8. Assert the deletion badge exists — the delete-queue count is now 1.
        //    PendingDeletionsButton is rendered with an accessibility label containing
        //    "1 items" when 1 asset is queued for deletion.
        let deletionButton = app.buttons["PendingDeletionsButton"]
        XCTAssertTrue(deletionButton.waitForExistence(timeout: 5),
            "Pending deletions button must exist after Mode 2 swipe-right")
        // Label format: "View pending deletions (1 items)"
        let matches = NSPredicate(format: "label CONTAINS[c] %@", "1 items")
        XCTAssertTrue(matches.evaluate(with: deletionButton),
            "Mode 2 swipe-right must have queued exactly 1 deletion; got label \(deletionButton.label)")
        // Deck must have advanced.
        XCTAssertEqual(progressCounter.label, "2 of 6",
            "swipe-right in Mode 2 must advance the deck")
    }
```

- [ ] **Step 2: Run the UI test**

In Xcode: Product → Test → filter to `SwipeSortUITests/testMode2SwipeRightDeletes`. This requires a simulator to be booted.

Expected: **PASS**. If it fails on the "Gesture Mode" row lookup, inspect the Accessibility Inspector output for the actual element type — some SwiftUI versions dispatch `.pickerStyle(.navigationLink)` as either a `button` or `staticText`. The test tries both, but if a third rendering is used the fallback must be extended.

- [ ] **Step 3: Commit**

```
Report line: "phase-5/task-15: added testMode2SwipeRightDeletes to SwipeSortUITests — real-navigation Mode 2 end-to-end coverage (F7)"
```

---

## Task 16 — F8: empty-library grid tap absence

**Files:**
- Modify: `SwipeSortUITests/SwipeSortUITests.swift` (extend `testEmptyPhotoLibraryDisplaysEmptyState` OR add a new sibling test)

**Scope note:** The finding says "verify tapping into the swipe deck from an empty library shows FinishedSummaryView." In practice, `SwipeStackView` is ONLY entered via a `ThumbnailCell` tap, and there are ZERO cells when the library is empty — so the deck cannot be entered from the UI. The `SwipeSessionModel.emptyLibraryFinishes` unit test in `SessionResumeTests.swift` already covers the model-level empty→finished transition. The remaining UI-level assertion is: with `--ui-testing-empty`, verify that `ThumbnailCell-0` does NOT exist — a regression that surfaces a cell when the library is empty would silently unlock a broken swipe-deck code path.

- [ ] **Step 1: Extend the existing test**

In `SwipeSortUITests/SwipeSortUITests.swift`, replace the existing `testEmptyPhotoLibraryDisplaysEmptyState` (lines 118–128):

```swift
    @MainActor
    func testEmptyPhotoLibraryDisplaysEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 5))
        let emptyText = app.staticTexts["No photos found."]
        XCTAssertTrue(emptyText.waitForExistence(timeout: 5), "Should display empty state text when library has 0 photos")
        XCTAssertTrue(app.staticTexts["Try adjusting the filter, or grant library access first."].exists)
    }
```

With:

```swift
    @MainActor
    func testEmptyPhotoLibraryDisplaysEmptyState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-empty"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 5))
        let emptyText = app.staticTexts["No photos found."]
        XCTAssertTrue(emptyText.waitForExistence(timeout: 5), "Should display empty state text when library has 0 photos")
        XCTAssertTrue(app.staticTexts["Try adjusting the filter, or grant library access first."].exists)

        // F8 extension: verify that with 0 assets, ZERO ThumbnailCell buttons are
        // rendered. If a regression surfaces a cell for an empty library, the swipe
        // deck could be entered against an empty session — a code path this test
        // guards against.
        let firstCell = app.buttons["ThumbnailCell-0"]
        XCTAssertFalse(firstCell.exists,
            "no ThumbnailCell may be present when assetCount == 0 — grid tap must not be reachable")
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSortUITests/testEmptyPhotoLibraryDisplaysEmptyState`. Expected: **PASS**.

```
Report line: "phase-5/task-16: extended testEmptyPhotoLibraryDisplaysEmptyState to assert absence of ThumbnailCell-0 — closes empty-library grid-tap scope (F8)"
```

---

## Task 17 — F16: launch-test hardening

**Files:**
- Modify: `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift` (replace `testLaunch` body)

- [ ] **Step 1: Replace the launch-test body**

In `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift`, replace the existing `testLaunch` (lines 20–34):

```swift
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
```

With:

```swift
    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // Launch with the standard --ui-testing flag so we're driving the mock
        // library and don't depend on the simulator's real photo permission dialog.
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // F16 fix: wait until the app is running-foreground; without this the test
        // silently passed even when the app crashed at launch.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
            "App must reach runningForeground state within 10s of launch")

        // F16 fix: assert the root nav bar is present — pins the tab-container view
        // as the launch destination. Any refactor that breaks initial view resolution
        // would surface here rather than silently in a downstream test.
        XCTAssertTrue(app.navigationBars["Recents"].waitForExistence(timeout: 10),
            "Recents navigation bar must be present after launch (tab-bar root view intact)")

        // Keep the screenshot for CI artifacts — but now it's a bonus, not the only
        // signal.
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
```

- [ ] **Step 2: Run & commit**

Run `SwipeSortUITestsLaunchTests/testLaunch`. Expected: **PASS**.

```
Report line: "phase-5/task-17: hardened testLaunch with runningForeground wait and Recents nav-bar assertion (F16)"
```

---

## Verification Pass

After all 17 tasks are complete, run this structural self-check.

- [ ] **Check 1: `nextRemoveResult` is declared and consumed in `MockPhotoLibrary`**

```
grep -n "nextRemoveResult" /home/harshal.patil/Documents/SwipeSort/SwipeSort/Core/MockPhotoLibrary.swift
```

Expected: at least 3 matches — declaration, read inside `removeAssetsFromAlbum`, `= nil` consumed-once reset.

- [ ] **Check 2: `nextThumbnailResult` is declared and consumed**

```
grep -n "nextThumbnailResult" /home/harshal.patil/Documents/SwipeSort/SwipeSort/Core/MockPhotoLibrary.swift
```

Expected: at least 3 matches — declaration, read inside `thumbnail(for:targetSize:)`, `= nil` reset.

- [ ] **Check 3: `setCurrentAuthorization` is defined**

```
grep -n "setCurrentAuthorization" /home/harshal.patil/Documents/SwipeSort/SwipeSort/Core/MockPhotoLibrary.swift
```

Expected: 1 match — the method declaration.

- [ ] **Check 4: F1 — undo-remove failure test exists**

```
grep -n "undoMoveFromNilSourceHandlesRemoveFailure" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/AlbumMoveTests.swift
```

Expected: 1 match.

- [ ] **Check 5: F2 — undo-from-finished test exists**

```
grep -n "undoFromFinishedRestoresReadyPhase" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/SessionResumeTests.swift
```

Expected: 1 match.

- [ ] **Check 6: F3 — concurrent-swipe test exists and uses async let**

```
grep -n "concurrentSwipesDoNotCorruptQueue\|async let first\|async let second" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/SwipeSessionModelTests.swift
```

Expected: 3 matches — the test name plus both `async let` lines.

- [ ] **Check 7: F4, F5, F18, F20 tests all exist in SwipeSessionModelTests**

```
grep -n "midSessionLibraryChangeDoesNotCorruptSwipe\|authRevocationMidSessionCurrentBehavior\|swipePrevAtIndexZeroIsNoOp\|removeFromDeletionQueueSingleId" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/SwipeSessionModelTests.swift
```

Expected: 4 matches.

- [ ] **Check 8: F9 — new ThumbnailDeliveryTests file exists**

```
grep -n "nilThumbnailOnStart\|degradedThumbnailOnStart" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/ThumbnailDeliveryTests.swift
```

Expected: 2 matches.

- [ ] **Check 9: F10 — mid-session filter test exists**

```
grep -n "applyFilterMidSessionDoesNotResetCursor" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/ApplyFilterRefreshTests.swift
```

Expected: 1 match.

- [ ] **Check 10: F13 — two undo-symmetry tests exist**

```
grep -n "undoMoveFromNilSourceCallsRemove\|undoMoveFromSourceCallsReversedMove" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/AlbumMoveTests.swift
```

Expected: 2 matches.

- [ ] **Check 11: F14 — zero-total window test exists**

```
grep -n "slideZeroTotalIsNoOp" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/WindowedThumbnailCacheTests.swift
```

Expected: 1 match.

- [ ] **Check 12: F17 — BulkDeleteTests now sets scriptedFilteredCount in deleteAllSubmitsBatch**

```
grep -n "scriptedFilteredCount = 3" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/BulkDeleteTests.swift
```

Expected: at least 1 match inside `deleteAllSubmitsBatch`.

- [ ] **Check 13: F19 — mode1RightPrev and mode2DownPrev exist**

```
grep -n "mode1RightPrev\|mode2DownPrev" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/SettingsIntegrationTests.swift
```

Expected: 2 matches.

- [ ] **Check 14: F7 — Mode 2 UI test exists**

```
grep -n "testMode2SwipeRightDeletes" /home/harshal.patil/Documents/SwipeSort/SwipeSortUITests/SwipeSortUITests.swift
```

Expected: 1 match.

- [ ] **Check 15: F8 — empty-library test asserts absence of ThumbnailCell-0**

```
grep -n "XCTAssertFalse(firstCell.exists" /home/harshal.patil/Documents/SwipeSort/SwipeSortUITests/SwipeSortUITests.swift
```

Expected: at least 1 match inside `testEmptyPhotoLibraryDisplaysEmptyState`.

- [ ] **Check 16: F16 — launch test contains wait(for: .runningForeground) and nav-bar assertion**

```
grep -n "runningForeground\|navigationBars\\[\"Recents\"\\]" /home/harshal.patil/Documents/SwipeSort/SwipeSortUITests/SwipeSortUITestsLaunchTests.swift
```

Expected: 2 matches — the `runningForeground` wait, the Recents nav bar assertion.

- [ ] **Check 17: All new test files use Swift Testing (not XCTest)**

```
grep -l "import XCTest" /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/MockPhotoLibraryScriptingTests.swift /home/harshal.patil/Documents/SwipeSort/SwipeSortTests/ThumbnailDeliveryTests.swift 2>/dev/null
```

Expected: **no output** (Swift Testing files must not import XCTest).

- [ ] **Check 18: Full test suite passes**

In Xcode: Product → Test (full suite).

Expected: **all tests PASS**. The final gate for Phase 5 execution.

---

## Working Set Coverage

| Finding | Severity | Task | Status |
|---|---|---|---|
| F1 — undo of moveToAlbum(nil source) untested against removeAssetsFromAlbum failure | high    | Task 2  | Covered |
| F2 — no undo test across `.finished` → `.ready` transition                          | high    | Task 3  | Covered |
| F3 — no concurrent-swipe regression test                                             | medium  | Task 4  | Covered |
| F4 — no mid-session PHPhotoLibraryChangeObserver test                                | high    | Task 5  | Covered (current-behavior pin) |
| F5 — no mid-session auth-revocation test                                             | high    | Task 6  | Covered (current-behavior pin) |
| F7 — Mode 2 gesture flow untested end-to-end at UI layer                             | medium  | Task 15 | Covered |
| F8 — empty-library swipe deck UI path not asserted                                   | medium  | Task 16 | Covered (scope-adjusted: cell absence) |
| F9 — thumbnail nil / degraded delivery untested                                      | medium  | Task 7  | Covered |
| F10 — mid-session filter change enforcement untested                                 | medium  | Task 8  | Covered (current-behavior pin) |
| F13 — undo symmetry (nil vs non-nil source) untested                                 | medium  | Task 9  | Covered (2 tests) |
| F14 — zero-total window boundary lacks explicit assertion (PARTIAL)                  | low     | Task 10 | Covered |
| F16 — launch test has no assertions (PARTIAL)                                        | low     | Task 17 | Covered |
| F17 — BulkDeleteTests filter fidelity was fake-positive                              | low     | Task 11 | Covered |
| F18 — swipePrev at index 0 no-op untested                                            | low     | Task 12 | Covered |
| F19 — mode1RightPrev and mode2DownPrev direction dispatches untested                 | low     | Task 13 | Covered (2 tests) |
| F20 — removeFromDeletionQueue method untested                                        | low     | Task 14 | Covered |

**Total: 16 findings covered** (14 LIVE + 2 PARTIAL). CLOSED findings (F6, F11, F12, F15) are not in scope.

---

## Production gaps flagged (out of scope, logged for future phases)

Phase 5 pins current behavior for three findings whose real risk is a production gap. A future phase must address:

1. **F4 — model does not re-validate `currentIndex` after a `PhotoLibraryChangePublisher` fire.** The mock's `refreshFetchResult()` is a no-op, so the test cannot exercise the true "asset shifted under cursor" scenario. Production fix: on didChangeNotification, call `library.refreshFetchResult()`, then verify `currentIndex < totalCount` (re-fetch count) and re-sync currentThumbnail.
2. **F5 — `SwipeSessionModel` checks authorization only in `start()`.** No mid-session revocation handler exists. Production fix: on entering `advance()` (or via a system-notification observer), re-check `library.currentAuthorization()` and transition to `.denied` if revoked.
3. **F10 — `applyFilter` is doc'd as "before start() only" but no runtime guard enforces it.** Production fix: assert `phase == .idle` at the top of `applyFilter`, or drive session-reset semantics when the filter changes mid-flight.

Each is a **production-code fix**, not a test-only fix — they should be scoped into a Phase 5 follow-up or a dedicated Phase 5.1 correctness sub-phase.

---

## Handoff

Plan saved to `/home/harshal.patil/Documents/SwipeSort/docs/superpowers/plans/2026-07-15-phase-5-testing.md`.

**Execution model:** Inline execution by the main session (mechanical test additions). Tasks 1 through 14 are backend-only and can be batched into a single implementer pass. Tasks 15 through 17 (UI tests) require a separate dispatch — they must be run in Xcode's simulator to verify the real Settings-navigation flow (Task 15) and the launch-foreground assertion (Task 17).

**Reviewer note:** After all 17 tasks land, a whole-branch adversarial review must verify (a) that every test fails obviously if the covered code regresses, (b) that no new mock hook leaked into unrelated existing test paths, and (c) that Task 15's UI test finds the Gesture Mode picker under the current SwiftUI accessibility rendering (may need a small fallback tweak).
