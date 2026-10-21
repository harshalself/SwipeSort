# Phase 1 — Decision-lifecycle correctness: working set

**Re-verified:** 2026-07-14 (post doc-comment pass, no code fixes applied yet)
**Source review:** docs/reviews/2026-07-13/

## Summary

- In-scope findings considered: 9
- Still present: 8
- Partially fixed: 0
- Already fixed: 0
- Rerouted to other phase: 1

---

## Working set — items to fix in Phase 1

### W1 — `swipeUp` double-executes album move [ORIGIN: correctness.md F1, SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:129–141
- **Status:** still-present
- **What (verbatim from source):** `swipeUp(intoAlbumId:)` calls `library.moveAssets(...)` directly, then also records a `.moveToAlbum` decision in the queue; if the caller later invokes `commitDecisions()` the move is never re-executed (see F2), but the decision remains in the queue and counts against `movedToAlbumCount`, misleading the summary. More critically, any code path that does attempt to re-commit moves (e.g., a future refactor of `commitDecisions` to handle moves) will issue the operation twice, moving the asset a second time or silently failing.
- **Failure scenario (verbatim from source):** User swipes an asset into Album A. The asset is immediately moved (correct). The decision is also stored. If the commit path is later extended to flush `.moveToAlbum` decisions (the natural next step), the asset is moved again — either into a duplicate album membership or triggering an error that surfaces as "Failed" to the user. Even today the summary shows an inflated `movedToAlbumCount` on `finishedSummary` after a delete commit because `removeCommitted()` only strips `.delete` decisions, leaving stale moves in the queue permanently.
- **Fix direction:** Adopt contract (a) — moves are fire-and-forget. Remove the `.moveToAlbum` case from `DecisionQueue.decisions` as a committed entry; instead maintain a separate `movedToAlbumCount` counter on `DecisionQueue` (or on `SwipeSessionModel` directly) that is incremented in `swipeUp` and never removed by `removeCommitted()`. This eliminates the stale-entry hazard while preserving the summary count and undo capability. `removeCommitted()` on `SwipeDecision` would then only concern itself with `.delete`, and the undo path for `.moveToAlbum` already uses the `popped` value from `undoLast()` without re-reading the queue. The `movedToAlbumCount` computed property on `SwipeSessionModel` must be updated to read the new counter rather than filtering the decisions array.
- **Depends on:** W3 (removeCommitted is touched by both fixes; coordinate so the queue-cleanup semantics are consistent)

---

### W2 — `commitDecisions()` exits early, skipping unflushed move decisions [ORIGIN: correctness.md F2, SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:289–292
- **Status:** still-present
- **What (verbatim from source):** `commitDecisions()` returns `.success(affectedCount: 0)` and sets `phase = .finished` immediately when `pendingDeletions` is empty, without processing any `.moveToAlbum` entries that might be in the queue.
- **Failure scenario (verbatim from source):** If the user only performs album-move swipes (no deletions) and then taps "Delete All" in `DeletionQueueView` or reaches the auto-commit path, `commitDecisions()` returns `success(0)` and sets `phase = .finished` without executing any moves. Under the current code, moves already fired immediately (F1), so no data loss occurs today — but the control flow is wrong: `phase` transitions to `.finished` unconditionally, which triggers the auto-present-queue or auto-commit path in `finishedSummary.task` even for sessions that had zero deletions. The guard is also the only protection if F1 is fixed (moves become deferred); at that point this early exit would silently drop all pending moves.
- **Fix direction:** Replace the single `guard !deleteIds.isEmpty` check with a check against the total work to be done (both deletions and any future deferred move work). Under the current fire-and-forget contract for moves (W1 option a), the `guard` should remain gated on deletions but its semantics must be clarified: it is "nothing to delete, skip to finished" — which is the correct early exit only when there are also no side-effects left pending. Add a comment making that invariant explicit. The deeper fix is also W4: `phase = .finished` must not be set unconditionally on `.cancelledByUser`, and the early-exit path should also verify there is no open commit state before flipping to `.finished`.
- **Depends on:** W4 (the `phase = .finished` placement is shared with the cancel-path bug)

---

### W3 — `removeCommitted()` only strips `.delete`; stale `.moveToAlbum` decisions accumulate [ORIGIN: correctness.md F8, SEVERITY: high]
- **File:** SwipeSort/Core/SwipeDecision.swift:89–94
- **Status:** still-present
- **What (verbatim from source):** After a successful commit, `removeCommitted()` deletes only `.delete` decisions. `.moveToAlbum` entries are never removed from `decisions`, causing `movedToAlbumCount` and `pendingDeletions` computations to grow unboundedly across repeated commit calls in a long session.
- **Failure scenario (verbatim from source):** User runs a 500-photo session; swipes 200 into albums (immediately executed) and 300 to delete. After commit, the 300 `.delete` entries are stripped but the 200 `.moveToAlbum` entries remain. If the user starts a new batch (add more photos to delete) and commits again, `movedToAlbumCount` still shows 200 from the previous batch on the summary screen, giving a false "Moved to Album: 200" count. More importantly, if F1 is fixed and moves are deferred, a second `commitDecisions()` call would re-execute all 200 stale moves.
- **Fix direction:** Under the fire-and-forget contract for moves (W1 option a): track move counts with a separate counter on `DecisionQueue` incremented by `record(.moveToAlbum...)` and never rolled back by `removeCommitted()`. The `.moveToAlbum` case can then be removed from the `decisions` array entirely after its counter has been incremented, eliminating unbounded accumulation. If retaining the full decision log for undo purposes is required, introduce a separate `committedMoveCount` that survives `removeCommitted()` and is used exclusively for summary display, while stale `.moveToAlbum` entries in `decisions` are stripped by `removeCommitted()` once undo is no longer possible (i.e., after `phase` transitions to `.finished`). unchanged from source in general approach; the key addition is the counter-vs-queue split.
- **Depends on:** W1 (the chosen W1 contract determines whether .moveToAlbum entries remain in the array at all)

---

### W4 — `commitDecisions()` sets `phase = .finished` before commit result is evaluated [ORIGIN: correctness.md F6, SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:294–296
- **Status:** still-present
- **What (verbatim from source):** `phase = .committing` is set before `library.commitDeletions` is awaited. If the user cancels the iOS system alert, `phase = .finished` is still set (line 296), and `queue.removeCommitted()` is only called on `.success`, so the queue is correctly preserved — but `phase` is permanently `.finished` even though there are still pending deletions.
- **Failure scenario (verbatim from source):** User has 10 photos queued for deletion, taps "Delete All", then cancels the iOS system alert. `CommitResult.cancelledByUser` is returned, the queue is preserved (correct), but `phase` is now `.finished`. The `finishedSummary` view renders and its `.task` fires the auto-present-queue / auto-commit path again, so the user cannot see a re-try path without restarting the session. The deletions remain pending in the queue but the UI is stuck on the finished screen.
- **Fix direction:** unchanged from source — only set `phase = .finished` on `.success`. On `.cancelledByUser` or `.failed`, revert `phase` to `.ready` so the user can retry from the swipe deck. The `finishedSummary` guard `commitResult == nil` already handles the "not yet committed" visual; `phase` must revert to make the deck interactive again.
- **Depends on:** none

---

### W5 — `undo()` silently navigates to index 0 when popped asset is not found [ORIGIN: correctness.md F4, SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:228–237
- **Status:** still-present
- **What (verbatim from source):** When the backward scan in `undo()` fails to locate the popped identifier (asset deleted externally, filter changed, or stale `localIdentifier`), `target` stays at its initialised value of `0`, so `currentIndex` jumps to the very first photo in the library rather than aborting or emitting a recoverable error.
- **Failure scenario (verbatim from source):** User swipes photo #4000, then the Photos library changes externally (iCloud sync deletes that asset) while the queue is still open. User taps Undo. The `while` loop exits without finding the asset, `target` is `0`, and the swipe view jumps to photo #1 — a completely wrong position. Because `phase` is also set to `.ready` and `loadCurrent()` is called, the user is now swiping photos they already reviewed.
- **Fix direction:** unchanged from source — initialise `target` as `nil` (change `var target = 0` to `var target: Int? = nil`). After the loop, if `target` is still `nil`, set `currentIndex = max(0, currentIndex - 1)` as a best-effort fallback (step back one position rather than jumping to 0) and surface an in-session warning to the user that the asset could not be found.
- **Depends on:** none

---

### W6 — `PhotoLibraryChangePublisher.register()` called before authorization is granted [ORIGIN: correctness.md F9, SEVERITY: high]
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:42–44
- **Status:** still-present
- **What (verbatim from source):** `PhotoLibraryChangePublisher.shared.register()` calls `PHPhotoLibrary.shared().register(self)` inside `init()`, which executes before the user has granted library access.
- **Failure scenario (verbatim from source):** On first launch the observer is registered without authorization; if access is later denied the observer still fires on any library change, triggering unnecessary `loadAssets()` / `loadAlbums()` re-indexing calls against an invalid fetch cursor.
- **Fix direction:** unchanged from source — remove `PhotoLibraryChangePublisher.shared.register()` from `PhotoKitLibrary.init()`. Move the call to the `.authorized` / `.limited` branch inside `SwipeSessionModel.start()` (after `await library.requestAuthorization()` returns a usable status, and also after `await library.currentAuthorization()` confirms it is already authorized on subsequent launches). Add a guard in `PhotoLibraryChangePublisher.register()` itself to make it idempotent (safe to call more than once without double-registering with `PHPhotoLibrary`).
- **Depends on:** none

---

### W7 — `swipeKeep()` silently sets `isFavorite = true` on every "kept" asset [ORIGIN: correctness.md F7, SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:96–97
- **Status:** still-present
- **What (verbatim from source):** `swipeKeep()` calls `swipeFavorite()` which always calls `library.setFavorite(..., isFavorite: true)` — there is no corresponding path that sets `isFavorite: false`, and `toggleFavorite()` is not wired to any gesture in `swipe(_:using:)`.
- **Failure scenario (verbatim from source):** The naming implies "keep" (do not delete, no favourites side-effect) but the implementation silently marks every "kept" photo as a Photos favourite. On a 50k-asset library where the user swipes "keep" on thousands of photos, all of those become favourites — a destructive change to the library that the user did not request.
- **Fix direction:** unchanged from source — separate the `.keep` semantic from the favouriting semantic. `swipeKeep()` should advance without any library side-effect (or alternatively be removed and all callsites updated to call `swipeNext()` for a true skip). Confirm in the gesture mapping in `swipe(_:using:)` that no direction silently routes through `swipeKeep()` — currently `swipe` calls `swipeFavorite()` directly (lines 186 and 193), not `swipeKeep()`, which is the correct behaviour. The only fix needed is ensuring `swipeKeep()` does not delegate to `swipeFavorite()`.
- **Depends on:** none

---

### W8 — `undo()` discards return value of `removeAssetsFromAlbum` for nil-fromAlbumId case [ORIGIN: correctness.md F10, SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:223
- **Status:** still-present
- **What (verbatim from source):** When `fromAlbumId` is `nil` (swiping from All Photos), undo calls `library.removeAssetsFromAlbum([id], albumId: toAlbumId)`. The return value is discarded (`_ = await ...`). If the original move returned an error the undo will attempt to remove an asset that was never added, which either no-ops or errors.
- **Failure scenario (verbatim from source):** Dry-run mode returns `.success` without actually moving (correct), but the decision is still enqueued. Undo then calls `removeAssetsFromAlbum` with the real library — which with dry-run OFF would attempt to remove the asset even though it was never added. The result is a spurious "remove from album" operation that does nothing (if the asset isn't in the album) but could be logged as an error or, in edge cases, could remove a legitimately placed asset.
- **Fix direction:** unchanged from source — check the result of `removeAssetsFromAlbum` in `undo()` and surface failures via an in-session warning rather than discarding. Additionally, do not record `.moveToAlbum` decisions in dry-run mode (skip `queue.record()` when the underlying `moveAssets` call is a dry-run no-op), or check `DryRunMode.isEnabled` in `undo()` before calling `removeAssetsFromAlbum`.
- **Depends on:** W1 (W1 determines whether .moveToAlbum is recorded in dry-run mode; the fix to W1 may already gate recording on move success)

---

### W9 — `swipePrev()` skips all decided assets, blocking backward navigation entirely [ORIGIN: correctness.md F16, SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:162–178
- **Status:** still-present
- **What (verbatim from source):** `swipePrev()` walks backward skipping assets that already have a decision in the queue. After an undo + re-decision cycle, a user could press "prev" repeatedly and never land on an asset they already decided on, contradicting the "see the previous photo" UX expectation.
- **Failure scenario (verbatim from source):** User swipes 5 photos (all keep), then presses "prev". The backward walk skips all 5 decided photos and returns nil (guard fires, `swipePrev` no-ops), leaving the user unable to navigate back at all — even though they can see via the UI that there are previous photos (the header shows "6 of 50").
- **Fix direction:** unchanged from source — re-evaluate the skip logic in `swipePrev()`. The cleanest fix is to remove the `decidedIDs` filter entirely so `swipePrev()` navigates to the nearest previous asset regardless of decision status (mirroring standard gallery "back" semantics). If the intent is to prevent re-deciding an asset, that guard belongs on the gesture that records a decision, not on navigation. Alternatively, document clearly that `swipePrev()` is "go to nearest undecided previous asset" and add a separate `navigatePrev()` that steps back unconditionally.
- **Depends on:** none

---

## Already fixed (dropped from Phase 1)

*(none — no in-scope findings were resolved by the doc-comment pass)*

---

## Rerouted to other phases

- **best-practices F1 — `PhotoKitLibrary` @unchecked Sendable with unsynchronised mutable state** — moved to Phase 2; reason: PHASES.md explicitly scopes `PhotoKitLibrary` actor/Sendable work to Phase 2; the finding's primary risk is concurrent mutation under async callers, not the decision-lifecycle state machine.

---

## Recommended fix order

1. **W4** — Revert `phase` to `.ready` on `.cancelledByUser`/`.failed`. Self-contained; no other item depends on it; can be verified with a unit test that returns `.cancelledByUser` from a mock library. Land first because it is the smallest, most isolated fix and establishes correct `phase` semantics that W2 builds on.

2. **W5** — Fix `undo()` nil-target fallback. Fully independent of queue semantics. Change `var target = 0` to `var target: Int? = nil` and add the not-found guard. Self-contained unit test path.

3. **W1 + W3** (bundle in one atomic commit) — Decide the move contract (fire-and-forget counter vs. deferred commit) and implement both the `swipeUp` side (W1) and the `removeCommitted` side (W3) together. These two items share the same data structure (`DecisionQueue.decisions` + `movedToAlbumCount`) and must land atomically to avoid an intermediate state where one is fixed but the other is inconsistent. Fix W3 first within the commit (change `removeCommitted()` to also handle the updated queue shape), then fix W1 (update `swipeUp` to use the new recording path).

4. **W2** — Fix the early-exit guard in `commitDecisions()`. Now safe to implement because W4 has already corrected the `phase = .finished` placement, so touching `commitDecisions()` won't re-introduce the cancel-path bug. Update comments to reflect the invariant.

5. **W6** — Move `register()` out of `PhotoKitLibrary.init()`. Wire it into `SwipeSessionModel.start()` post-authorization. Make `register()` idempotent. This is independent of the queue fixes but is listed after them because `AlbumGridView.getScopedLibrary()` also calls `PhotoKitLibrary(albumId:)` — the fix must account for all init() call sites or the guard in `register()` must protect against re-registration (making order less critical).

6. **W7** — Decouple `swipeKeep()` from `swipeFavorite()`. Straightforward alias removal. Independent of all queue fixes.

7. **W8** (any order after W1) — Guard `undo()` dry-run path and surface `removeAssetsFromAlbum` failure. Depends on W1 resolving whether moves are recorded in dry-run mode.

8. **W9** (any order, independent) — Remove or document the `decidedIDs` filter in `swipePrev()`. Purely navigational; no queue or phase dependencies.

---

## Testing follow-ups (Phase 5 input)

- Test that `commitDecisions()` with `.cancelledByUser` leaves `phase == .ready` and the deletion queue intact (W4 regression).
- Test that a second call to `commitDecisions()` after a successful first commit does not re-execute or inflate move counts (W1/W3 regression).
- Test `undo()` when the popped identifier is not present in the fetch result — assert `currentIndex` does not jump to 0 (W5 regression).
- Test `swipeUp` followed by `undo()` in dry-run mode — assert no spurious `removeAssetsFromAlbum` call is issued (W8 regression).
- Test `swipePrev()` when all previous assets have decisions — assert it navigates to the nearest previous asset rather than no-oping (W9 regression, post-fix).
- Test `PhotoKitLibrary.init()` does not trigger `PHPhotoLibrary.register()` before authorization is confirmed — mock `PHPhotoLibrary` at the call site or verify `PhotoLibraryChangePublisher.register()` is not called until the post-auth branch of `SwipeSessionModel.start()` (W6 regression).
- Test that `movedToAlbumCount` resets to 0 (or stays accurate) after a commit cycle when the user performs a new batch of moves (W3 regression, multi-commit scenario).
