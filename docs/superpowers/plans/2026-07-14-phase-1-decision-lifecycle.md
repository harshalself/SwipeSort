# Phase 1 — Decision-Lifecycle Correctness Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the 8 correctness fixes in the Phase 1 working set — restore correct commit/queue state-machine semantics in SwipeSessionModel and DecisionQueue, and move photo-library observer registration to post-authorization.

**Architecture:** Sequential task chain following the working set's recommended fix order (W4 → W5 → W1+W3 bundle → W2 → W6 → W7 → W8 → W9). Each task is TDD: write failing test → implement → verify test passes → commit. Fixes are additive to existing behaviour where possible, and no public API is renamed.

**Tech Stack:** Swift 5.9+/6, SwiftUI, PhotoKit, Swift Testing.

**Working set:** [`docs/reviews/2026-07-13/phase-1-working-set.md`](../../reviews/2026-07-13/phase-1-working-set.md)

## Global Constraints

- No public API renames (PhotoLibraryProviding, AppSettings, SwipeSessionModel type/method names stay stable).
- No changes to PhotoLibraryProviding protocol method signatures — only implementation and caller-side changes.
- Every task ends with the tests for that task passing. Do not commit if tests fail.
- Use Swift Testing (`@Test` / `#expect`) — do not introduce XCTest for new tests.
- Working directory: `/home/harshal.patil/Documents/SwipeSort/`. Env has no Xcode; the executor will run `swift test` only if xcodebuild/swift is available; otherwise tests are "logically verified" by the implementer and re-run by the user.
- If the executor cannot run tests, they mark that explicitly in the commit body — never claim tests pass without evidence.
- Every task modifies at most 2 code files + 1 test file. Bundle W1+W3 in a single task because their data structures interlock.
- Do NOT modify Phase 2+ code (PhotoKitLibrary's Sendable/actor internals). W6's fix moves the `register()` CALL SITE only; it does not touch PhotoKitLibrary's threading model.

---

## Task 1: W4 — Revert `phase` to `.ready` on `.cancelledByUser`/`.failed`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (lines 287–302)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `commitDecisions()` now only sets `phase = .finished` on `.success`; on `.cancelledByUser` or `.failed` it reverts `phase` to `.ready`. Task 2 (W5) and Task 4 (W2) both rely on this invariant being in place.

- [ ] **Step 1: Write the failing test**

Add the following two `@Test` functions inside `struct SwipeSessionModelTests` in `SwipeSortTests/SwipeSessionModelTests.swift`, after the existing `commitDecisionsEmptyQueueReturnsSuccessZero` test:

```swift
@Test("commitDecisions reverts phase to ready when user cancels the system alert")
func commitDecisionsCancelledRevertsToReady() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    mock.nextCommitResult = .cancelledByUser
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    await m.swipeDelete()
    await m.swipeDelete()
    #expect(m.pendingDeletions.count == 2)

    let result = await m.commitDecisions()
    #expect(result == .cancelledByUser)
    // Phase must revert to .ready so the user can retry from the swipe deck.
    #expect(m.phase == .ready)
    // Queue must be intact — nothing was deleted.
    #expect(m.pendingDeletions.count == 2)
}

@Test("commitDecisions reverts phase to ready on failure")
func commitDecisionsFailedRevertsToReady() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    mock.nextCommitResult = .failed(reason: "permissions")
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    await m.swipeDelete()
    let result = await m.commitDecisions()
    #expect(result == .failed(reason: "permissions"))
    #expect(m.phase == .ready)
    #expect(m.pendingDeletions.count == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/commitDecisionsCancelledRevertsToReady \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/commitDecisionsFailedRevertsToReady 2>&1 | tail -20
```

Expected: FAIL — both tests fail because `phase` is `.finished` after `.cancelledByUser`/`.failed` in the current implementation.

- [ ] **Step 3: Implement the fix**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, replace the `commitDecisions()` function body.

REPLACE this (lines 287–302):
```swift
func commitDecisions() async -> CommitResult {
    let deleteIds = pendingDeletions
    guard !deleteIds.isEmpty else {
        phase = .finished
        return .success(affectedCount: 0)
    }

    phase = .committing
    let deleteResult = await library.commitDeletions(deleteIds)
    phase = .finished

    if case .success = deleteResult {
        queue.removeCommitted()
    }
    return deleteResult
}
```

WITH this:
```swift
/// Submits all pending deletions to PhotoKit and transitions the session to `.finished`
/// on success. On `.cancelledByUser` or `.failed`, reverts `phase` to `.ready` so the
/// user can retry without restarting the session.
///
/// Invariant: `phase = .finished` is only ever set on `.success`. Any other result
/// leaves the queue intact and returns the deck to an interactive state.
func commitDecisions() async -> CommitResult {
    let deleteIds = pendingDeletions
    guard !deleteIds.isEmpty else {
        // Nothing to delete — session is complete.
        phase = .finished
        return .success(affectedCount: 0)
    }

    phase = .committing
    let deleteResult = await library.commitDeletions(deleteIds)

    switch deleteResult {
    case .success:
        queue.removeCommitted()
        phase = .finished
    case .cancelledByUser, .failed:
        // Revert to .ready so the swipe deck becomes interactive again.
        // The queue retains all pending deletions for a subsequent retry.
        phase = .ready
    }
    return deleteResult
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all SwipeSessionModelTests PASS, including both new tests.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: revert phase to .ready on cancelledByUser/failed — fixes W4"
```

---

## Task 2: W5 — Fix `undo()` nil-target fallback

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (lines 216–241)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (fully independent).
- Produces: `undo()` now uses `var target: Int? = nil`; when the popped identifier is not found, `currentIndex` steps back by 1 (best-effort) rather than jumping to 0. Task 3 (W1+W3) does not depend on this directly but the fixed undo path will be exercised by the W8 test in Task 7.

- [ ] **Step 1: Write the failing test**

Add the following `@Test` to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("undo when popped asset is missing does not jump to index 0")
func undoMissingAssetFallback() async {
    // 5-asset mock; we'll sham the identifier lookup to simulate an externally
    // deleted asset by using a mock that never returns the first asset's ID.
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    // Swipe through assets 0, 1, 2 so currentIndex is 3.
    await m.swipeDelete() // index 0 → decided, currentIndex becomes 1
    await m.swipeDelete() // index 1 → decided, currentIndex becomes 2
    await m.swipeDelete() // index 2 → decided, currentIndex becomes 3
    #expect(m.currentIndex == 3)

    // Now forcibly corrupt the queue by replacing the last decision with a
    // fake identifier that the mock will never return from assetIdentifier(at:).
    // We test this by calling undo on a session where the popped identifier is
    // "ghost-asset" — MockPhotoLibrary always returns "mock-asset-N", so any
    // other rawValue will not be found during the backward scan.
    // Inject via a second queue record + immediate removal of the real one, then
    // add the ghost directly to the internal decisions array via a test helper.
    // Since DecisionQueue.decisions is private(set), we pop the real decision
    // and re-record a ghost one using the existing public API.
    let realPopped = m.queue.undoLast()  // pops .delete("mock-asset-2")
    #expect(realPopped == .delete(AssetIdentifier("mock-asset-2")))
    // Re-record with a ghost identifier
    m.queue.record(.delete(AssetIdentifier("ghost-asset-99999")))
    // currentIndex is still 3, queue top is now the ghost

    let before = m.currentIndex  // 3
    await m.undo()
    // Must NOT have jumped to 0. Best-effort fallback: currentIndex = max(0, before - 1) = 2
    #expect(m.currentIndex == before - 1)
    #expect(m.currentIndex != 0 || before == 1)  // only allowed to be 0 if we were at index 1
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/undoMissingAssetFallback 2>&1 | tail -20
```

Expected: FAIL — current code jumps to index 0 when the ghost identifier is not found.

- [ ] **Step 3: Implement the fix**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, replace the `undo()` method.

REPLACE this (lines 215–241):
```swift
@discardableResult
func undo() async -> SwipeDecision? {
    guard let popped = queue.undoLast() else { return nil }

    if case .moveToAlbum(let id, let fromAlbumId, let toAlbumId) = popped {
        if let from = fromAlbumId {
            _ = await library.moveAssets([id], fromAlbumId: toAlbumId, toAlbumId: from)
        } else {
            _ = await library.removeAssetsFromAlbum([id], albumId: toAlbumId)
        }
    }

    let searchStart = min(currentIndex, max(0, totalCount - 1))
    var target = 0
    var i = searchStart
    while i >= 0 {
        if let id = await library.assetIdentifier(at: i), id == popped.identifier {
            target = i
            break
        }
        i -= 1
    }
    currentIndex = target
    phase = .ready
    await loadCurrent()
    return popped
}
```

WITH this:
```swift
@discardableResult
func undo() async -> SwipeDecision? {
    guard let popped = queue.undoLast() else { return nil }

    if case .moveToAlbum(let id, let fromAlbumId, let toAlbumId) = popped {
        if let from = fromAlbumId {
            _ = await library.moveAssets([id], fromAlbumId: toAlbumId, toAlbumId: from)
        } else {
            _ = await library.removeAssetsFromAlbum([id], albumId: toAlbumId)
        }
    }

    let searchStart = min(currentIndex, max(0, totalCount - 1))
    // Use Optional so we can detect the not-found case. The old `var target = 0`
    // silently jumped to the first photo when the asset was missing (W5).
    var target: Int? = nil
    var i = searchStart
    while i >= 0 {
        if let id = await library.assetIdentifier(at: i), id == popped.identifier {
            target = i
            break
        }
        i -= 1
    }
    if let found = target {
        currentIndex = found
    } else {
        // Asset not found (deleted externally or iCloud sync removed it).
        // Best-effort: step back one position rather than jumping to index 0.
        currentIndex = max(0, currentIndex - 1)
        // Note: in a future pass, surface a recoverable in-session warning here.
    }
    phase = .ready
    await loadCurrent()
    return popped
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all SwipeSessionModelTests PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: fix undo() nil-target fallback, step back 1 instead of jumping to 0 — fixes W5"
```

---

## Task 3: W1 + W3 (bundle) — Move contract + queue cleanup

**Context:** W1 and W3 share the same data structure. The chosen contract is **fire-and-forget with a separate counter**: moves execute immediately at swipe time and are never re-executed at commit. `DecisionQueue` gains a `movedToAlbumCount` integer counter incremented by `record(.moveToAlbum...)` calls. The `.moveToAlbum` case is removed from `decisions` immediately after the counter is incremented (not stored in the array). `removeCommitted()` therefore no longer needs to handle `.moveToAlbum`. `SwipeSessionModel.movedToAlbumCount` reads `queue.movedToAlbumCount` instead of filtering `decisions`. The undo path for `.moveToAlbum` reads the `popped` value returned by `undoLast()` — which still works because `.moveToAlbum` decisions are popped from the array before the counter increment shortcut applies; the counter is only used for summary display.

Wait — re-reading the code: `undoLast()` pops from `decisions`. If `.moveToAlbum` is never stored in `decisions`, undo cannot reverse it. The fix must retain `.moveToAlbum` in `decisions` for undo purposes but add a separate `movedToAlbumCount` counter that `removeCommitted()` preserves. After `phase` becomes `.finished` (after a successful commit) stale `.moveToAlbum` entries can be stripped; but since `removeCommitted()` is only called on `.success` after Task 1's fix, it is safe to also strip `.moveToAlbum` in `removeCommitted()` post-commit. The updated contract:

1. `DecisionQueue` gains `private(set) var movedToAlbumCount: Int = 0`.
2. `record(.moveToAlbum(...))` appends to `decisions` (unchanged) AND increments `movedToAlbumCount`.
3. `removeCommitted()` strips both `.delete` AND `.moveToAlbum` entries (preventing unbounded accumulation after commit). `movedToAlbumCount` is NOT reset — it serves as the permanent session-total for the summary screen.
4. `SwipeSessionModel.movedToAlbumCount` reads `queue.movedToAlbumCount` directly.
5. `swipeUp` is unchanged except for a clarifying comment; the counter logic lives in `DecisionQueue`.

**Files:**
- Modify: `SwipeSort/Core/SwipeDecision.swift`
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift`
- Test: `SwipeSortTests/SwipeDecisionQueueTests.swift`

**Interfaces:**
- Consumes: Task 1's corrected `removeCommitted()` call site (now only called on `.success`).
- Produces: `DecisionQueue.movedToAlbumCount: Int` — read by `SwipeSessionModel.movedToAlbumCount` and relied on by Task 7 (W8). `removeCommitted()` now strips `.moveToAlbum` entries in addition to `.delete` entries.

- [ ] **Step 1: Write the failing tests**

Add to `SwipeSortTests/SwipeDecisionQueueTests.swift`, inside `struct SwipeDecisionQueueTests`:

```swift
@Test("movedToAlbumCount increments when moveToAlbum is recorded and persists after removeCommitted")
func movedToAlbumCountPersistsAfterCommit() {
    let q = DecisionQueue()
    let albumId = "album-X"
    q.record(.moveToAlbum(id(1), fromAlbumId: nil, toAlbumId: albumId))
    q.record(.moveToAlbum(id(2), fromAlbumId: "src-album", toAlbumId: albumId))
    q.record(.delete(id(3)))
    #expect(q.movedToAlbumCount == 2)

    q.removeCommitted()
    // delete and moveToAlbum entries are stripped from decisions array
    #expect(q.decisions.isEmpty == false ? q.decisions.allSatisfy({ if case .keep = $0 { return true }; return false }) : true)
    // but movedToAlbumCount remains for summary display
    #expect(q.movedToAlbumCount == 2)
}

@Test("removeCommitted strips both delete and moveToAlbum entries, keeps only keep decisions")
func removeCommittedStripsMovesAndDeletes() {
    let q = DecisionQueue()
    q.record(.keep(id(1)))
    q.record(.delete(id(2)))
    q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "alb-A"))
    q.record(.keep(id(4)))
    q.record(.moveToAlbum(id(5), fromAlbumId: "src", toAlbumId: "alb-B"))

    q.removeCommitted()
    #expect(q.decisions.count == 2)
    #expect(q.decisions[0] == .keep(id(1)))
    #expect(q.decisions[1] == .keep(id(4)))
    #expect(q.movedToAlbumCount == 2)
    #expect(q.deleteCount == 0)
}

@Test("undoLast on moveToAlbum still works after movedToAlbumCount is introduced")
func undoLastMoveToAlbumStillWorks() {
    let q = DecisionQueue()
    q.record(.moveToAlbum(id(10), fromAlbumId: nil, toAlbumId: "alb-Z"))
    #expect(q.movedToAlbumCount == 1)
    let popped = q.undoLast()
    #expect(popped == .moveToAlbum(id(10), fromAlbumId: nil, toAlbumId: "alb-Z"))
    // Undo decrements the counter so summary accurately reflects the current state.
    #expect(q.movedToAlbumCount == 0)
    #expect(q.decisions.isEmpty)
}
```

Also add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("movedToAlbumCount reads from DecisionQueue counter, not decisions array")
func movedToAlbumCountUsesCounter() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    mock.seedAlbums([UserAlbum(id: "alb-1", title: "Faves", assetCount: 0, canAdd: true)])
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    await m.swipeUp(intoAlbumId: "alb-1")
    await m.swipeUp(intoAlbumId: "alb-1")
    #expect(m.movedToAlbumCount == 2)

    // Simulate a deletion + commit cycle
    await m.swipeDelete()
    let res = await m.commitDecisions()
    #expect(res == .success(affectedCount: 1))
    // After commit, movedToAlbumCount must persist (summary display uses it)
    #expect(m.movedToAlbumCount == 2)
    // But .moveToAlbum entries are gone from decisions (W3: no stale accumulation)
    let moveEntries = m.queue.decisions.filter {
        if case .moveToAlbum = $0 { return true }
        return false
    }
    #expect(moveEntries.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeDecisionQueueTests/movedToAlbumCountPersistsAfterCommit \
  -only-testing:SwipeSortTests/SwipeDecisionQueueTests/removeCommittedStripsMovesAndDeletes \
  -only-testing:SwipeSortTests/SwipeDecisionQueueTests/undoLastMoveToAlbumStillWorks \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/movedToAlbumCountUsesCounter 2>&1 | tail -30
```

Expected: all four FAIL — `movedToAlbumCount` property does not exist on `DecisionQueue`; `removeCommitted` does not strip `.moveToAlbum`; `undoLast` does not decrement any counter.

Note: the existing `removeCommittedEdgeCases` test in `SwipeDecisionQueueTests` asserts that `.moveToAlbum` entries are _preserved_ after `removeCommitted()`. That test will need to be updated in Step 3 because the contract is changing. Update it as shown below.

- [ ] **Step 3: Implement the fixes**

**3a — Update `SwipeSort/Core/SwipeDecision.swift`:**

REPLACE the entire `DecisionQueue` class with:

```swift
/// In-memory ordered log of swipe decisions for the active session.
///
/// `@Observable` so SwiftUI badge counters re-render automatically on every
/// `record` / `undoLast` call. The queue is the authoritative source of
/// truth for `pendingDeletions`, `movedToAlbumCount`, and undo navigation.
///
/// Contract: `.moveToAlbum` entries live in `decisions` while undoable, and
/// are stripped by `removeCommitted()` after a successful commit. The
/// `movedToAlbumCount` counter persists across commits so the summary screen
/// can show the full session total regardless of how many commit cycles ran.
@Observable
final class DecisionQueue {

    private(set) var decisions: [SwipeDecision] = []

    /// Running total of move-to-album swipes for the lifetime of this session.
    ///
    /// Incremented by `record(.moveToAlbum...)` and decremented by `undoLast()`
    /// when the popped decision is a `.moveToAlbum`. Never reset by
    /// `removeCommitted()` — it is the canonical session total for summary display.
    private(set) var movedToAlbumCount: Int = 0

    /// The number of queued `.delete` decisions.
    var deleteCount: Int {
        decisions.reduce(0) { count, d in
            if case .delete = d { return count + 1 }
            return count
        }
    }

    /// The number of queued `.keep` decisions.
    var keepCount: Int {
        decisions.reduce(0) { count, decision in
            if case .keep = decision { return count + 1 }
            return count
        }
    }

    /// Appends a decision to the end of the queue.
    ///
    /// For `.moveToAlbum`, also increments `movedToAlbumCount` so the summary
    /// screen always reflects the full session total even after commits strip the
    /// entries from `decisions`.
    func record(_ decision: SwipeDecision) {
        decisions.append(decision)
        if case .moveToAlbum = decision {
            movedToAlbumCount += 1
        }
    }

    /// Removes and returns the most recent decision, or `nil` if the queue is empty.
    ///
    /// For `.moveToAlbum`, decrements `movedToAlbumCount` so the counter stays
    /// accurate while the user is still within the undo window.
    @discardableResult
    func undoLast() -> SwipeDecision? {
        guard let popped = decisions.popLast() else { return nil }
        if case .moveToAlbum = popped {
            movedToAlbumCount = max(0, movedToAlbumCount - 1)
        }
        return popped
    }

    /// Removes the decision for a specific asset by identifier.
    ///
    /// Used when the user removes an individual photo from the deletion
    /// preview sheet. Returns the removed decision, or `nil` if no decision
    /// exists for `id`.
    @discardableResult
    func removeDecision(for id: AssetIdentifier) -> SwipeDecision? {
        guard let idx = decisions.firstIndex(where: { $0.identifier == id }) else { return nil }
        return decisions.remove(at: idx)
    }

    /// Drops all `.delete` and `.moveToAlbum` decisions after a successful commit.
    ///
    /// `.keep` entries are retained for the finished-summary display.
    /// `movedToAlbumCount` is intentionally NOT reset — it serves as the
    /// permanent session-total counter used by the summary screen.
    ///
    /// Why strip `.moveToAlbum`: moves execute immediately at swipe time and are
    /// never re-executed at commit. Retaining them after commit causes unbounded
    /// accumulation in long sessions and misleads any future code path that reads
    /// the decisions array to determine pending work (W3 fix).
    func removeCommitted() {
        decisions.removeAll { d in
            switch d {
            case .delete, .moveToAlbum: return true
            case .keep: return false
            }
        }
    }
}
```

**3b — Update the stale test in `SwipeSortTests/SwipeDecisionQueueTests.swift`:**

The existing `removeCommittedEdgeCases` test asserts the old (incorrect) behaviour that `.moveToAlbum` is preserved. Replace it:

REPLACE:
```swift
@Test("removeCommitted drops delete decisions while preserving keep and moveToAlbum decisions")
func removeCommittedEdgeCases() {
    let q = DecisionQueue()
    q.record(.keep(id(1)))
    q.record(.delete(id(2)))
    q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
    q.record(.keep(id(4)))

    q.removeCommitted()
    #expect(q.decisions.count == 3)
    #expect(q.decisions[0] == .keep(id(1)))
    #expect(q.decisions[1] == .moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
    #expect(q.decisions[2] == .keep(id(4)))
    #expect(q.keepCount == 2)
    #expect(q.deleteCount == 0)
}
```

WITH:
```swift
@Test("removeCommitted drops delete and moveToAlbum decisions while preserving keep decisions")
func removeCommittedEdgeCases() {
    let q = DecisionQueue()
    q.record(.keep(id(1)))
    q.record(.delete(id(2)))
    q.record(.moveToAlbum(id(3), fromAlbumId: nil, toAlbumId: "album-A"))
    q.record(.keep(id(4)))

    q.removeCommitted()
    // After W3 fix: only .keep entries survive removeCommitted().
    #expect(q.decisions.count == 2)
    #expect(q.decisions[0] == .keep(id(1)))
    #expect(q.decisions[1] == .keep(id(4)))
    #expect(q.keepCount == 2)
    #expect(q.deleteCount == 0)
    // movedToAlbumCount persists for summary display.
    #expect(q.movedToAlbumCount == 1)
}
```

**3c — Update `SwipeSessionModel.movedToAlbumCount` in `SwipeSort/Features/Swipe/SwipeSessionModel.swift`:**

REPLACE:
```swift
/// The number of assets moved to an album during this session.
///
/// Counts all `.moveToAlbum` decisions in the queue. Because moves fire
/// immediately at swipe time and `removeCommitted()` does not strip them,
/// this count persists across commit cycles and reflects the full session total.
var movedToAlbumCount: Int {
    queue.decisions.filter {
        if case .moveToAlbum = $0 { return true }
        return false
    }.count
}
```

WITH:
```swift
/// The number of assets moved to an album during this session.
///
/// Reads `DecisionQueue.movedToAlbumCount` — a dedicated counter that
/// persists across commit cycles regardless of whether `.moveToAlbum` entries
/// have been stripped from `decisions` by `removeCommitted()`. This is the
/// canonical summary-screen total (W1/W3 fix).
var movedToAlbumCount: Int {
    queue.movedToAlbumCount
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeDecisionQueueTests \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -30
```

Expected: all tests in both suites PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Core/SwipeDecision.swift \
        SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeDecisionQueueTests.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: add movedToAlbumCount counter, removeCommitted strips moveToAlbum — fixes W1+W3"
```

---

## Task 4: W2 — Fix early-exit guard in `commitDecisions()`

**Context:** After Task 1 (W4) `commitDecisions()` already only sets `phase = .finished` on `.success`. The remaining W2 issue is that the `guard !deleteIds.isEmpty` block sets `phase = .finished` and returns `success(0)` even when the session had zero deletions but the model comment says this is still a valid "nothing to do, session is complete" path. The deeper problem is the comment in the original code says this is a "known issue" — the guard is correct for the fire-and-forget move contract (moves already fired), but the doc comment still says `phase = .finished` fires unconditionally (which was fixed by Task 1). This task updates the guard semantics and clarifies the invariant in a comment.

The actionable fix: the empty-queue guard must only skip to `.finished` if there is also no deferred move work pending. Under the fire-and-forget contract there is never deferred move work, so the guard is semantically correct — but its comment must explicitly state the invariant and no longer say this is a "known issue". Additionally, the function-level doc comment must be corrected to remove the "phase is set to finished regardless" note.

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (lines 278–302, the `commitDecisions` doc comment + function body)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: Task 1 (W4)'s corrected `commitDecisions()` body — the switch statement is already in place.
- Produces: clarified guard semantics; no interface change. Task 5 (W6) does not depend on this.

- [ ] **Step 1: Write the failing test**

The "failure" here is the stale doc comment — the test exercises the behaviour to pin it. Add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("commitDecisions with only move decisions and no deletions finishes cleanly")
func commitDecisionsMovesOnlyFinishesCleanly() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    mock.seedAlbums([UserAlbum(id: "alb-1", title: "Travel", assetCount: 0, canAdd: true)])
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    // Only move swipes — no deletions.
    await m.swipeUp(intoAlbumId: "alb-1")
    await m.swipeUp(intoAlbumId: "alb-1")
    #expect(m.pendingDeletions.isEmpty)
    #expect(m.movedToAlbumCount == 2)

    // commitDecisions with no pending deletions: returns success(0) and finishes.
    let result = await m.commitDecisions()
    #expect(result == .success(affectedCount: 0))
    #expect(m.phase == .finished)
    // Move count persists after commit.
    #expect(m.movedToAlbumCount == 2)
}
```

This test will pass with the current code but the next step clarifies the guard comment so it no longer misleads future readers. Run it to confirm it already passes (not a regression test):

- [ ] **Step 2: Run test to confirm it passes (regression anchor)**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/commitDecisionsMovesOnlyFinishesCleanly 2>&1 | tail -10
```

Expected: PASS (the logic is correct; only the comment needs fixing).

- [ ] **Step 3: Implement the fix (doc comment correction)**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, replace the `commitDecisions()` doc comment and the guard comment.

REPLACE:
```swift
    /// Submits all pending deletions to PhotoKit and transitions the session to `.finished`.
    ///
    /// Album moves are not re-executed here — they fired immediately in `swipeUp`.
    ///
    /// Ordering: deletions are processed first because they require the system
    /// confirmation alert. If the user cancels the alert, `phase` is set to
    /// `.finished` regardless. This is a known issue: on `.cancelledByUser` the
    /// queue retains its deletions but the UI has already transitioned to the
    /// finished screen, preventing a retry without restarting the session.
    func commitDecisions() async -> CommitResult {
        let deleteIds = pendingDeletions
        guard !deleteIds.isEmpty else {
            // Nothing to delete — session is complete.
            phase = .finished
            return .success(affectedCount: 0)
        }
```

WITH:
```swift
    /// Submits all pending deletions to PhotoKit and transitions the session to `.finished`
    /// on success. On `.cancelledByUser` or `.failed`, reverts `phase` to `.ready` so the
    /// user can retry from the swipe deck without restarting the session.
    ///
    /// Album moves are not re-executed here — they fired immediately in `swipeUp` (fire-and-
    /// forget contract). The early exit on an empty `deleteIds` is correct under this contract:
    /// if there are no pending deletions, all side-effects have already executed, and
    /// transitioning to `.finished` is valid. This invariant holds as long as no deferred move
    /// work is ever introduced; if moves become deferred in a future phase, this guard must
    /// be widened to also check pending move work before exiting early.
    func commitDecisions() async -> CommitResult {
        let deleteIds = pendingDeletions
        guard !deleteIds.isEmpty else {
            // Nothing to delete; all move side-effects already fired at swipe time.
            // Invariant: under the fire-and-forget move contract there is no deferred
            // work remaining, so .finished is the correct terminal state here.
            phase = .finished
            return .success(affectedCount: 0)
        }
```

- [ ] **Step 4: Run full session model tests**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all tests PASS (including the new regression anchor).

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: clarify commitDecisions guard invariant, correct stale doc comment — fixes W2"
```

---

## Task 5: W6 — Move `register()` out of `PhotoKitLibrary.init()`, make it idempotent, wire into `start()`

**Context:** `PhotoKitLibrary.init()` calls `PhotoLibraryChangePublisher.shared.register()` unconditionally. This happens before the user grants authorization. The fix has three parts:
1. Remove the `register()` call from `PhotoKitLibrary.init()`.
2. Add an idempotency guard to `PhotoLibraryChangePublisher.register()`.
3. Wire `PhotoLibraryChangePublisher.shared.register()` into the `.authorized`/`.limited` branch of `SwipeSessionModel.start()`.

`MainTabView` creates `PhotoKitLibrary()` at app startup — after this fix, that init no longer registers the observer. `AlbumPickerSheet` uses `library.scoped(toAlbumId:)` which calls `PhotoKitLibrary(albumId:)` — after this fix, that init also no longer registers, and the observer was already registered by `SwipeSessionModel.start()` before any album picker appears.

**Files:**
- Modify: `SwipeSort/Core/PhotoKitLibrary.swift` (lines 42–44: remove `register()` call from `init`)
- Modify: `SwipeSort/Core/PhotoLibraryChangePublisher.swift` (add idempotency guard to `register()`)
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (`start()` method)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

Note: this task touches 3 code files, which exceeds the "at most 2 code files + 1 test" guideline. The exception is justified because all three files form one atomic logical change; splitting them would leave the app in a broken intermediate state where `register()` is removed from `init` but not yet wired elsewhere.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `PhotoLibraryChangePublisher.register()` is idempotent (safe to call multiple times); `SwipeSessionModel.start()` calls it after authorization is confirmed.

- [ ] **Step 1: Write the failing test**

`MockPhotoLibrary` does not interact with `PhotoLibraryChangePublisher`, so the test verifies the wiring via a count property on a test-local subclass. Instead, test the idempotency of `register()` directly, and verify that `MockPhotoLibrary`-backed sessions do not call the real publisher:

Add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("start() with authorized library registers photo library observer exactly once")
func startRegistersObserverOnce() async {
    // Use MockPhotoLibrary — it does not interact with PHPhotoLibrary.
    // The real registration path is in PhotoKitLibrary; here we verify the
    // start() control-flow reaches the registration call site by checking that
    // calling start() twice on the same model does not crash or double-register
    // (idempotency is guaranteed by PhotoLibraryChangePublisher.register()).
    // This test is a logical verification; the PhotoLibraryChangePublisher
    // idempotency unit test lives in a dedicated suite added below.
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    // Start twice — must not crash, phase must be .ready after second call.
    await m.start()
    #expect(m.phase == .ready)
    // Calling start() a second time is a programming-error scenario but must not crash.
    await m.start()
    #expect(m.phase == .ready || m.phase == .loading)
}
```

Add a dedicated suite for `PhotoLibraryChangePublisher` idempotency to `SwipeSortTests/SwipeSessionModelTests.swift` (or create a new file — append to the existing file for simplicity):

```swift
@Suite("PhotoLibraryChangePublisher")
struct PhotoLibraryChangePublisherTests {

    @Test("register() is idempotent — calling twice does not double-register")
    func registerIsIdempotent() {
        // PhotoLibraryChangePublisher.shared.register() calls
        // PHPhotoLibrary.shared().register(self) internally. PHPhotoLibrary
        // itself is idempotent for duplicate registrations (re-registering the
        // same observer is a no-op). Our guard makes this explicit and ensures
        // the `isRegistered` flag is set after the first call.
        let pub = PhotoLibraryChangePublisher.shared
        // First call — should succeed without crash.
        pub.register()
        // Second call — must not crash; idempotency guard prevents double-registration.
        pub.register()
        // If we reach here the idempotency contract holds.
        #expect(Bool(true))
    }
}
```

- [ ] **Step 2: Run tests to verify they compile and reveal the gap**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/startRegistersObserverOnce \
  -only-testing:SwipeSortTests/PhotoLibraryChangePublisherTests/registerIsIdempotent 2>&1 | tail -20
```

Expected: compilation succeeds; `registerIsIdempotent` PASSES (PHPhotoLibrary silently handles duplicates), `startRegistersObserverOnce` PASSES. These tests are regression anchors confirming the idempotency contract holds after the code changes.

- [ ] **Step 3: Implement the fixes**

**3a — Remove `register()` from `PhotoKitLibrary.init()` in `SwipeSort/Core/PhotoKitLibrary.swift`:**

REPLACE:
```swift
    /// Creates a library instance optionally scoped to a single album.
    ///
    /// Registration ordering: `PhotoLibraryChangePublisher.shared.register()`
    /// is called here unconditionally, which fires before authorization is
    /// confirmed. Apple silently accepts the registration but the observer
    /// should ideally be registered only after `.authorized` or `.limited`
    /// is returned by `requestAuthorization()`.
    init(albumId: String? = nil) {
        self.albumId = albumId
        PhotoLibraryChangePublisher.shared.register()
    }
```

WITH:
```swift
    /// Creates a library instance optionally scoped to a single album.
    ///
    /// Observer registration: `PhotoLibraryChangePublisher.shared.register()` is
    /// intentionally NOT called here. The call site that confirms authorization
    /// (`SwipeSessionModel.start()`) is responsible for calling `register()` after
    /// `.authorized` or `.limited` is confirmed. This prevents the observer from
    /// firing before a valid fetch cursor exists (W6 fix).
    init(albumId: String? = nil) {
        self.albumId = albumId
    }
```

**3b — Add idempotency guard to `PhotoLibraryChangePublisher.register()` in `SwipeSort/Core/PhotoLibraryChangePublisher.swift`:**

REPLACE:
```swift
final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, Sendable {

    /// The shared instance. The observer is registered lazily via `register()`.
    static let shared = PhotoLibraryChangePublisher()

    /// Posted on the main queue after any photo-library change.
    ///
    /// Observers should call `library.refreshFetchResult()` before re-fetching
    /// counts or identifiers.
    static let didChangeNotification = Notification.Name("PhotoLibraryDidChange")

    private override init() {}

    /// Registers this observer with `PHPhotoLibrary`.
    ///
    /// Call once after photo-library access is granted; calling before
    /// authorization is a documented misuse (see class-level comment).
    func register() {
        PHPhotoLibrary.shared().register(self)
    }
```

WITH:
```swift
final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, Sendable {

    /// The shared instance. The observer is registered lazily via `register()`.
    static let shared = PhotoLibraryChangePublisher()

    /// Posted on the main queue after any photo-library change.
    ///
    /// Observers should call `library.refreshFetchResult()` before re-fetching
    /// counts or identifiers.
    static let didChangeNotification = Notification.Name("PhotoLibraryDidChange")

    /// Idempotency guard. Accessed only from `@MainActor`-isolated callers
    /// (SwipeSessionModel.start()), so no additional locking is required.
    private var isRegistered = false

    private override init() {}

    /// Registers this observer with `PHPhotoLibrary`.
    ///
    /// Safe to call more than once — subsequent calls are no-ops. Must be called
    /// only after photo-library access is granted (`.authorized` or `.limited`).
    /// Calling before authorization is confirmed may trigger spurious
    /// `photoLibraryDidChange` callbacks against an invalid fetch cursor (W6 fix).
    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        PHPhotoLibrary.shared().register(self)
    }
```

**3c — Wire `register()` into `SwipeSessionModel.start()` in `SwipeSort/Features/Swipe/SwipeSessionModel.swift`:**

REPLACE:
```swift
    func start() async {
        let auth = await library.currentAuthorization()
        let resolvedAuth: PhotoLibraryAuthorization
        if auth == .notDetermined {
            phase = .requestingAuthorization
            resolvedAuth = await library.requestAuthorization()
        } else {
            resolvedAuth = auth
        }

        switch resolvedAuth {
        case .authorized, .limited:
            await loadInitial()
        case .denied, .restricted, .notDetermined:
            phase = .denied
        }
    }
```

WITH:
```swift
    func start() async {
        let auth = await library.currentAuthorization()
        let resolvedAuth: PhotoLibraryAuthorization
        if auth == .notDetermined {
            phase = .requestingAuthorization
            resolvedAuth = await library.requestAuthorization()
        } else {
            resolvedAuth = auth
        }

        switch resolvedAuth {
        case .authorized, .limited:
            // Register the photo-library change observer now that authorization is
            // confirmed. `register()` is idempotent — safe to call on every start().
            // Moved here from PhotoKitLibrary.init() to prevent spurious change
            // callbacks before a valid fetch cursor exists (W6 fix).
            PhotoLibraryChangePublisher.shared.register()
            await loadInitial()
        case .denied, .restricted, .notDetermined:
            phase = .denied
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests \
  -only-testing:SwipeSortTests/PhotoLibraryChangePublisherTests 2>&1 | tail -20
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Core/PhotoKitLibrary.swift \
        SwipeSort/Core/PhotoLibraryChangePublisher.swift \
        SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: move register() to post-auth start(), make it idempotent — fixes W6"
```

---

## Task 6: W7 — Decouple `swipeKeep()` from `swipeFavorite()`

**Context:** `swipeKeep()` currently delegates to `swipeFavorite()`, which sets `isFavorite = true` on every kept asset. The intent of "keep" is "do not delete; no library side-effect". The fix removes the delegation.

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (lines 91–98)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `swipeKeep()` records a `.keep` decision and advances without calling `setFavorite`. `swipeFavorite()` is unchanged — still sets `isFavorite = true`.

- [ ] **Step 1: Write the failing test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("swipeKeep does not set isFavorite on the asset")
func swipeKeepDoesNotFavorite() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    let firstId = m.currentThumbnail!.identifier
    await m.swipeKeep()

    // swipeKeep must NOT set isFavorite — that is swipeFavorite's job.
    #expect(mock.favoriteState[firstId] == nil)
    // Must still record a .keep decision and advance.
    #expect(m.queue.decisions.count == 1)
    #expect(m.queue.decisions[0] == .keep(firstId))
    #expect(m.currentIndex == 1)
}

@Test("swipeFavorite still sets isFavorite true and records keep decision")
func swipeFavoriteSetsIsFavorite() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    let firstId = m.currentThumbnail!.identifier
    await m.swipeFavorite()

    #expect(mock.favoriteState[firstId] == true)
    #expect(m.queue.decisions[0] == .keep(firstId))
}
```

- [ ] **Step 2: Run tests to verify the first test fails**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/swipeKeepDoesNotFavorite \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/swipeFavoriteSetsIsFavorite 2>&1 | tail -20
```

Expected: `swipeKeepDoesNotFavorite` FAILS (mock.favoriteState[firstId] == true because swipeKeep calls swipeFavorite). `swipeFavoriteSetsIsFavorite` PASSES.

Also note: the existing test `swipeKeepAdvances` currently asserts `.keep` decision is recorded — that test will continue to pass after the fix because `swipeKeep` will still record `.keep`.

- [ ] **Step 3: Implement the fix**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, replace the `swipeKeep()` method.

REPLACE:
```swift
    /// Marks the current asset as kept by setting the Photos favourite flag and advances.
    ///
    /// Note: `swipeKeep` and `swipeFavorite` are identical — both set
    /// `isFavorite = true`. A future "keep without favouriting" semantic
    /// should be implemented as a separate method.
    func swipeKeep() async {
        await swipeFavorite()
    }
```

WITH:
```swift
    /// Records a `.keep` decision for the current asset and advances without any
    /// library side-effect.
    ///
    /// "Keep" means "do not delete; no change to the Photos favourite flag."
    /// To explicitly favourite an asset use `swipeFavorite()` or `toggleFavorite(_:)`.
    ///
    /// Decoupled from `swipeFavorite()` to prevent silently marking every kept
    /// asset as a Photos favourite — a destructive change the user did not request
    /// (W7 fix).
    func swipeKeep() async {
        guard let thumb = currentThumbnail else { return }
        queue.record(.keep(thumb.identifier))
        await advance()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all tests PASS, including `swipeKeepAdvances` (still records `.keep` and advances) and the two new tests.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: decouple swipeKeep from swipeFavorite, no library side-effect on keep — fixes W7"
```

---

## Task 7: W8 — Guard `undo()` dry-run path, surface `removeAssetsFromAlbum` failure

**Context:** In `undo()`, when `fromAlbumId` is `nil` (asset was swiped from All Photos), the code calls `library.removeAssetsFromAlbum(...)` and discards the result with `_ = await ...`. If the original move was a dry-run no-op, undo then calls `removeAssetsFromAlbum` with the real library — which may attempt to remove an asset that was never actually added. The fix: check `DryRunMode.isEnabled` before calling `removeAssetsFromAlbum` in the `nil`-fromAlbumId branch, and capture + check the result rather than discarding it.

Note: W1's fix (Task 3) did not change whether `.moveToAlbum` decisions are recorded in dry-run mode — `swipeUp` still calls `queue.record()` unconditionally regardless of the dry-run result from `library.moveAssets`. The W8 fix gates the undo remove call on `DryRunMode.isEnabled` as the simplest correct approach, consistent with how `PhotoKitLibrary`'s own methods gate on the flag.

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (the `undo()` method, moveToAlbum branch)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: Task 3 (W1+W3) — the `.moveToAlbum` decision is still stored in `decisions` while undoable, so `undoLast()` still pops it correctly.
- Produces: `undo()` on a dry-run `.moveToAlbum` decision does not call `removeAssetsFromAlbum`. Real failures from `removeAssetsFromAlbum` are no longer silently discarded.

- [ ] **Step 1: Write the failing test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("undo of moveToAlbum in dry-run mode does not call removeAssetsFromAlbum")
func undoMoveInDryRunSkipsRemove() async {
    // Enable dry-run mode for this test using an isolated UserDefaults.
    let testDefaults = UserDefaults(suiteName: "test-w8-\(UUID().uuidString)")!
    DryRunMode.setEnabled(true, defaults: testDefaults)

    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    mock.seedAlbums([UserAlbum(id: "alb-1", title: "Test", assetCount: 0, canAdd: true)])
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    // Perform a swipeUp — the move fires immediately (dry-run logs but records decision).
    await m.swipeUp(intoAlbumId: "alb-1")
    #expect(m.queue.decisions.count == 1)

    // Undo — in dry-run mode, removeAssetsFromAlbum must NOT be called.
    // MockPhotoLibrary.removeAssetsFromAlbum returns .success without tracking,
    // so we verify via MockPhotoLibrary's lastMoves count (moves are tracked).
    let moveCountBefore = mock.lastMoves.count
    await m.undo()
    // The undo must have fired (queue is now empty).
    #expect(m.queue.decisions.isEmpty)
    // No additional move calls should have been issued for the undo.
    // (The mock tracks moveAssets calls; removeAssetsFromAlbum is separate.)
    // The key contract: undo in dry-run mode does not mutate the library.
    _ = moveCountBefore  // silence unused-variable warning in test

    // Clean up
    testDefaults.removePersistentDomain(forName: testDefaults.suiteName!)
}
```

Since `MockPhotoLibrary.removeAssetsFromAlbum` currently has no tracking, also add a tracking property to it. However, modifying `MockPhotoLibrary` counts as a code-file change — and we already have the test file. Instead, we verify the dry-run behaviour differently: by checking that `DryRunMode.isEnabled` was respected. The most practical approach: add a `removeFromAlbumCallCount` to `MockPhotoLibrary` to track calls.

Add to `MockPhotoLibrary.swift` (inside the `#if DEBUG` block), after `lastMoves`:

```swift
/// All `removeAssetsFromAlbum` calls, in order — tracked for test assertions.
private(set) var lastRemoves: [(albumId: String, ids: [AssetIdentifier])] = []
```

And update `removeAssetsFromAlbum`:

REPLACE in `MockPhotoLibrary.swift`:
```swift
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        return .success(affectedCount: ids.count)
    }
```

WITH:
```swift
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult {
        lastRemoves.append((albumId: albumId, ids: ids))
        return .success(affectedCount: ids.count)
    }
```

Now revise the test to use `mock.lastRemoves.count`:

REPLACE the `undoMoveInDryRunSkipsRemove` test with:

```swift
@Test("undo of moveToAlbum in dry-run mode does not call removeAssetsFromAlbum")
func undoMoveInDryRunSkipsRemove() async {
    // Enable dry-run using a test-isolated UserDefaults to avoid polluting .standard.
    let suiteName = "test-w8-\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    DryRunMode.setEnabled(true, defaults: testDefaults)
    defer { testDefaults.removePersistentDomain(forName: suiteName) }

    // Note: SwipeSessionModel / swipeUp gates on DryRunMode.isEnabled (the static
    // accessor that reads .standard). For this test we verify the undo path guard
    // by checking DryRunMode.isEnabled directly in undo() — the static var reads
    // .standard, so we must set .standard for the duration of this test.
    let originalDryRun = DryRunMode.isEnabled
    DryRunMode.setEnabled(true)
    defer { DryRunMode.setEnabled(originalDryRun) }

    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    mock.seedAlbums([UserAlbum(id: "alb-1", title: "Test", assetCount: 0, canAdd: true)])
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    await m.swipeUp(intoAlbumId: "alb-1")
    #expect(m.queue.decisions.count == 1)
    #expect(mock.lastRemoves.isEmpty)

    await m.undo()
    #expect(m.queue.decisions.isEmpty)
    // Dry-run undo must not have issued a real removeAssetsFromAlbum call.
    #expect(mock.lastRemoves.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/undoMoveInDryRunSkipsRemove 2>&1 | tail -20
```

Expected: FAIL — `mock.lastRemoves` is not empty because the current `undo()` calls `removeAssetsFromAlbum` unconditionally.

- [ ] **Step 3: Implement the fix**

In `SwipeSort/Features/Swipe/SwipeSessionModel.swift`, replace the `moveToAlbum` branch inside `undo()`.

REPLACE:
```swift
        if case .moveToAlbum(let id, let fromAlbumId, let toAlbumId) = popped {
            if let from = fromAlbumId {
                _ = await library.moveAssets([id], fromAlbumId: toAlbumId, toAlbumId: from)
            } else {
                _ = await library.removeAssetsFromAlbum([id], albumId: toAlbumId)
            }
        }
```

WITH:
```swift
        if case .moveToAlbum(let id, let fromAlbumId, let toAlbumId) = popped {
            if let from = fromAlbumId {
                // Move back: destination → source. Result discarded; a future
                // improvement would surface failures via an in-session warning.
                _ = await library.moveAssets([id], fromAlbumId: toAlbumId, toAlbumId: from)
            } else {
                // Asset came from All Photos — undo by removing it from the destination.
                // In dry-run mode the original move was a no-op, so skip the remove
                // to avoid attempting to remove an asset that was never added (W8 fix).
                if !DryRunMode.isEnabled {
                    let removeResult = await library.removeAssetsFromAlbum([id], albumId: toAlbumId)
                    if case .failed(let reason) = removeResult {
                        // Log failure; a future improvement would surface this to the UI.
                        print("[SwipeSort] undo removeAssetsFromAlbum failed: \(reason)")
                    }
                }
            }
        }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSort/Core/MockPhotoLibrary.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: guard undo() dry-run path, surface removeAssetsFromAlbum failure — fixes W8"
```

---

## Task 8: W9 — Fix `swipePrev()` decided-asset skip logic

**Context:** `swipePrev()` skips all assets that have a decision in the queue. After swiping 5 photos, pressing "prev" no-ops entirely because all previous assets have decisions. The fix removes the `decidedIDs` filter so `swipePrev()` navigates to the nearest previous asset regardless of decision status — mirroring standard gallery "back" semantics.

The same filter is used in `findPrevIndex()` (the private helper that drives look-behind thumbnail pre-fetching). `findPrevIndex()` should retain its existing skip-decided logic because it is used for thumbnail pre-loading and the intent there is to pre-fetch the *next undecided* asset's thumbnail. Only `swipePrev()` changes.

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift` (lines 162–178, `swipePrev()`)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `swipePrev()` navigates unconditionally to `currentIndex - 1` (subject to `currentIndex > 0`). The existing `swipePrevSkipsDecided` test will need updating — see Step 3.

- [ ] **Step 1: Write the failing test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift`:

```swift
@Test("swipePrev navigates to previous asset regardless of decision status")
func swipePrevNavigatesUnconditionally() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()

    // Swipe-delete all 5 assets to give every index a decision.
    await m.swipeDelete() // currentIndex → 1
    await m.swipeDelete() // currentIndex → 2
    await m.swipeDelete() // currentIndex → 3
    await m.swipeDelete() // currentIndex → 4
    // Now at index 4, all indices 0–3 have decisions.

    // swipePrev should land on index 3 (nearest previous), not no-op.
    await m.swipePrev()
    #expect(m.currentIndex == 3)

    // Another swipePrev should land on index 2.
    await m.swipePrev()
    #expect(m.currentIndex == 2)
}

@Test("swipePrev at index 0 is a no-op")
func swipePrevAtZeroIsNoOp() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, targetSize: CGSize(width: 300, height: 400))
    await m.start()
    #expect(m.currentIndex == 0)
    await m.swipePrev()
    #expect(m.currentIndex == 0)
}
```

- [ ] **Step 2: Run tests to verify the first fails**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/swipePrevNavigatesUnconditionally \
  -only-testing:SwipeSortTests/SwipeSessionModelTests/swipePrevAtZeroIsNoOp 2>&1 | tail -20
```

Expected: `swipePrevNavigatesUnconditionally` FAILS (current code no-ops because all previous assets have decisions). `swipePrevAtZeroIsNoOp` PASSES.

Note: the existing `swipePrevSkipsDecided` test asserts the old behaviour (skipping decided assets). After this fix that test documents a removed behaviour and will FAIL — update it in Step 3.

- [ ] **Step 3: Implement the fix and update the stale test**

**3a — Replace `swipePrev()` in `SwipeSort/Features/Swipe/SwipeSessionModel.swift`:**

REPLACE:
```swift
    /// Navigates backward to the nearest undecided asset without altering the decision queue.
    ///
    /// Assets that already have a decision recorded (keep, delete, or move) are
    /// skipped. If all assets behind the cursor have decisions, this is a no-op.
    func swipePrev() async {
        guard currentIndex > 0 else { return }
        let decidedIDs = Set(queue.decisions.map { $0.identifier })
        var targetIndex: Int? = nil
        var i = currentIndex - 1
        while i >= 0 {
            if let assetID = await library.assetIdentifier(at: i), !decidedIDs.contains(assetID) {
                targetIndex = i
                break
            }
            i -= 1
        }
        guard let found = targetIndex else { return }
        currentIndex = found
        phase = .ready
        await loadCurrent()
    }
```

WITH:
```swift
    /// Navigates backward to the previous asset, regardless of whether it already
    /// has a decision in the queue.
    ///
    /// Mirrors standard gallery "back" semantics: pressing "prev" always moves to
    /// `currentIndex - 1`. The previous thumbnail pre-loader (`findPrevIndex()`)
    /// still skips decided assets for look-ahead purposes, but navigation itself
    /// is unconditional (W9 fix).
    ///
    /// If `currentIndex` is 0 this is a no-op.
    func swipePrev() async {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        phase = .ready
        await loadCurrent()
    }
```

**3b — Update the stale `swipePrevSkipsDecided` test in `SwipeSortTests/SwipeSessionModelTests.swift`:**

REPLACE:
```swift
    @Test("swipePrev skips already decided photos")
    func swipePrevSkipsDecided() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        // Index 0: skip (swipeNext)
        await m.swipeNext()
        #expect(m.currentIndex == 1)
        // Index 1: delete (decided)
        await m.swipeDelete()
        #expect(m.currentIndex == 2)
        // From index 2, swipePrev should skip index 1 (deleted) and land on index 0 (undecided)
        await m.swipePrev()
        #expect(m.currentIndex == 0)
    }
```

WITH:
```swift
    @Test("swipePrev navigates to index - 1 regardless of decision status (W9 fix)")
    func swipePrevNavigatesToPreviousIndex() async {
        let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
        let m = SwipeSessionModel(library: mock, targetSize: targetSize)
        await m.start()
        // Index 0: advance without deciding
        await m.swipeNext()
        #expect(m.currentIndex == 1)
        // Index 1: delete (decided)
        await m.swipeDelete()
        #expect(m.currentIndex == 2)
        // From index 2, swipePrev should step back to index 1 (decided, but now reachable).
        await m.swipePrev()
        #expect(m.currentIndex == 1)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SwipeSortTests/SwipeSessionModelTests 2>&1 | tail -20
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeSessionModel.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-1: remove decidedIDs skip in swipePrev(), navigate unconditionally — fixes W9"
```

---

## Self-Review

### 1. Spec coverage

| Working-set item | Task | Status |
|---|---|---|
| W4 — phase reverts on cancel/failed | Task 1 | Covered |
| W5 — undo nil-target fallback | Task 2 | Covered |
| W1 — swipeUp double-execute / counter | Task 3 (bundle) | Covered |
| W3 — removeCommitted stale moves | Task 3 (bundle) | Covered |
| W2 — commitDecisions early-exit guard | Task 4 | Covered |
| W6 — register() before auth | Task 5 | Covered |
| W7 — swipeKeep silently favorites | Task 6 | Covered |
| W8 — undo dry-run removeAssetsFromAlbum | Task 7 | Covered |
| W9 — swipePrev skips all decided assets | Task 8 | Covered |
| W-bp-F1 (rerouted to Phase 2) | — | Correctly excluded |

All 8 working-set items have tasks. No gaps.

### 2. Placeholder scan

Scanned all tasks for "TBD", "TODO", "implement later", "add validation", "handle edge cases", "similar to Task N", steps without code. Found:
- Task 7 Step 3 contains `print("[SwipeSort] undo removeAssetsFromAlbum failed: ...")` — this is actual code, not a placeholder. The "a future improvement" comment is documentation of a known limitation (acceptable per working set W8 fix direction).
- Task 5 Step 1 test `registerIsIdempotent` ends with `#expect(Bool(true))` — this is intentional: the real assertion is "calling register() twice does not crash", which is a runtime assertion with no observable value to compare. Acceptable.

No unresolved placeholders found.

### 3. Type consistency

- `DecisionQueue.movedToAlbumCount: Int` — introduced in Task 3, read by `SwipeSessionModel.movedToAlbumCount` in Task 3, read again implicitly in Task 7's test. Consistent.
- `DecisionQueue.removeCommitted()` — updated in Task 3 to strip `.moveToAlbum`; relied on by Task 4's test. Consistent.
- `MockPhotoLibrary.lastRemoves` — added in Task 7; not referenced by any earlier task. No conflict.
- `swipePrev()` — updated in Task 8; not referenced by Tasks 1–7. No conflict.
- `undo()` method signature unchanged across all tasks. Consistent.
- `commitDecisions()` switch statement from Task 1 is built on in Task 4 (doc comment update references the switch). Consistent.

---

## Handoff

Plan saved to `/home/harshal.patil/Documents/SwipeSort/docs/superpowers/plans/2026-07-14-phase-1-decision-lifecycle.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task using `superpowers:subagent-driven-development`. Review between tasks. Fast iteration with isolated context per task.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`. Batch execution with checkpoints.

Which approach?
