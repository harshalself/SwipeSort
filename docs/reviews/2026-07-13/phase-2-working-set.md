# Phase 2 — Concurrency + Sendable safety: working set

**Re-verified:** 2026-07-14 (post Phase 1)
**Source review:** docs/reviews/2026-07-13/
**Depends on:** Phase 1 complete (SwipeSessionModel decision-lifecycle fixes landed)

## Summary

- In-scope findings considered: 6 (correctness F3 + best-practices F1 merged into one; best-practices F2; correctness F11, F12, F14, F15)
- Still present: 2 (W1, W2)
- Partially fixed: 0
- Already fixed: 1 (correctness F15 — WindowedThumbnailCache.slide())
- Rerouted to other phase: 3 (correctness F11 → Phase 3; correctness F12 → Phase 4; correctness F14 → Phase 3)
- New concurrency issues surfaced by re-verify: 2 (N1, N2)

---

## Working set — items to fix in Phase 2

### W1 — PhotoKitLibrary @unchecked Sendable with unsynchronised mutable state [ORIGIN: correctness.md F3 + best-practices.md F1 (rerouted from Phase 1 working set), SEVERITY: high/medium]
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:27–33
- **Status:** still-present
- **What:** `PhotoKitLibrary` is declared `final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable` while holding three unprotected mutable stored properties — `fetchResult` (line 30), `fetchedAuth` (line 31), and `activeFilter` (line 32) — with no lock, actor isolation, or `nonisolated(unsafe)` annotation. Any concurrent async caller can read and write these properties without coordination.
- **Failure scenario:** `refreshFetchResult()` (line 498) sets `fetchResult = nil`. If a `PHPhotoLibraryChangeObserver` callback triggers `refreshFetchResult()` on a background queue dispatch while `ensureFetchResult()` (line 474) is simultaneously executing on the main actor — reading `fetchResult`, evaluating the guard, and writing a new value — one of the following can occur: (1) the nil written by `refreshFetchResult()` races the nil-check in `ensureFetchResult()`, causing the guard to pass on both paths and issuing two simultaneous `PHAsset.fetchAssets` calls, each writing `fetchResult` with potentially different results; (2) `fetchedAuth` is written before the new fetch completes, caching a stale empty result; (3) `applyFilter()` (line 505) sets `activeFilter = filter` and `fetchResult = nil` simultaneously with `ensureFetchResult()` reading `activeFilter` to build `options`, producing a cursor built against the old filter but cached under the new one. Under Swift 6 strict concurrency this is a compile error; with `@unchecked` it silently races. Even today, `refreshFetchResult()` is dispatched from `PhotoLibraryChangePublisher.photoLibraryDidChange` via `DispatchQueue.main.async` — meaning all call sites are effectively on the main actor in the current implementation — but this is not enforced by the type system and any future off-main call site would introduce a live race.
- **Fix direction:** Add `@MainActor` isolation to `PhotoKitLibrary`. This makes all three mutable properties main-actor-isolated, eliminates the need for `@unchecked Sendable` (a `@MainActor`-isolated class satisfies `Sendable` because crossing the actor boundary requires `await`), and keeps the synchronous `startCachingThumbnails`/`stopCachingThumbnails` protocol requirements callable without `await` from `WindowedThumbnailCache` (which is also `@MainActor`). A full `actor` upgrade would also work but requires making the synchronous caching methods either `nonisolated` (losing actor protection on `PHCachingImageManager`) or async (breaking the protocol surface and all callers) — `@MainActor` avoids that conflict. After the change: replace `@unchecked Sendable` with `Sendable` (or remove it and let the protocol conformance carry it) and update `PhotoLibraryProviding`'s threading comment to document the `@MainActor` requirement.
- **Depends on:** W2 (MockPhotoLibrary must mirror the isolation choice so the protocol conformance remains consistent between real and test implementations)

---

### W2 — MockPhotoLibrary @unchecked Sendable with unsynchronised mutable state [ORIGIN: best-practices.md F2, SEVERITY: medium]
- **File:** SwipeSort/Core/MockPhotoLibrary.swift:19
- **Status:** still-present
- **What:** `MockPhotoLibrary` is declared `final class MockPhotoLibrary: PhotoLibraryProviding, @unchecked Sendable` while holding more than a dozen mutable stored properties that are written during and between test calls — including `lastCommittedDeletions` (line 25), `albums` (line 29), `lastMoves` (line 31), `lastRemoves` (line 33), `favoriteState` (line 35), `scriptedMediaKinds` (line 44), `startCachingCalls` (line 46), `stopCachingCalls` (line 48), and others — with no synchronisation.
- **Failure scenario:** Any test that exercises concurrent async paths (e.g., `SwipeSessionModel.loadCurrent()` dispatches four `async let` branches: `currentThumbTask`, `currentKindTask`, `nextThumbTask`, `prevThumbTask`) can race on `scriptedMediaKinds` or `albums` if those properties are mutated between the test setup and the async call. The Phase 1 regression test `swipeUpAfterPrevAppendsBothMoves` drives `swipeUp` followed by `swipePrev`, which calls `loadCurrent()`'s four concurrent branches — all of which reach into `MockPhotoLibrary` concurrently. Under `@unchecked Sendable` the race is invisible and produces non-deterministic results in CI. `lastRemoves` (added to support W8 test assertions) is a `private(set) var` read in test assertions after an `await` boundary and written inside `removeAssetsFromAlbum` — if the test runner ever drives these concurrently, the assertion may observe a partial list.
- **Fix direction:** Mirror the isolation choice made for `PhotoKitLibrary` in W1. If `PhotoKitLibrary` becomes `@MainActor`, add `@MainActor` to `MockPhotoLibrary` as well. Since Swift Testing runs test functions on the main actor by default (per the existing doc comment at line 15), `@MainActor` isolation adds zero runtime cost in tests while making the conformance sound. Update the threading note in the class doc comment to reference `@MainActor` rather than the current "effectively serial" disclaimer.
- **Depends on:** W1 (the protocol conformance must remain consistent — both real and mock implementations must use the same isolation)

---

## Already fixed (dropped from Phase 2)

- **correctness.md F15 — WindowedThumbnailCache.slide() not guarded against concurrent calls** — `WindowedThumbnailCache` is annotated `@MainActor` at line 23 of `SwipeSort/Core/WindowedThumbnailCache.swift`. Because `slide(to:total:)` is an instance method on a `@MainActor`-isolated class, it is implicitly `@MainActor`-isolated and serialized on the main actor; the `Task { await thumbnailCache?.slide(...) }` created in `SwipeStackView.onChange` hops to the main actor before executing the body. The Phase 1 doc-comment pass (Task 11) added lines 18–22 explicitly confirming this invariant. No code change is needed; the finding was a "pending verification" that verifies safe.

- **correctness.md F9 / Phase-1 W6 — PhotoLibraryChangePublisher.register() called before authorization** — Fixed in Phase 1 Task 5. `PhotoKitLibrary.init()` (line 42–44 of `PhotoKitLibrary.swift`) no longer calls `register()`; the call moved to the `.authorized`/`.limited` branch of `SwipeSessionModel.start()` (line 89). `PhotoLibraryChangePublisher.register()` is now idempotent (line 42: `guard !isRegistered else { return }`). Not double-counted here; listed for completeness.

---

## Rerouted to other phases

- **correctness.md F11 — BulkDeleteView.applyFilter mutates shared library state** — Phase 3; reason: the concurrency hazard (unsynchronized `activeFilter` write) is eliminated by W1, but the root defect is architectural — two independent views sharing a single `PhotoLibraryProviding` instance, causing one view's filter change to affect the other's asset index space. That is a shared-ownership design problem, not a thread-safety problem. Phase 3's scope explicitly includes splitting `PhotoLibraryProviding` into narrower sub-protocols and architectural cleanup.

- **correctness.md F12 — livePhoto(for:) continuation may hang indefinitely on a dropped iCloud connection** — Phase 4; reason: the defect is a missing `withTaskCancellationHandler` and timeout path for a slow-network iCloud fetch, which is an iCloud fetch failure path explicitly listed in Phase 4's scope. The Phase 1 doc-comment pass already acknowledged this at `PhotoKitLibrary.swift` lines 411–416 ("A production fix would add a withTaskCancellationHandler and a timeout path"). No actor-boundary or Sendable issue; the continuation hangs within a single isolated context.

- **correctness.md F14 — AlbumGridView.getScopedLibrary() called in body, may construct multiple PhotoKitLibrary instances** — Phase 3; reason: the original observer-registration hazard (each `PhotoKitLibrary(albumId:)` in `getScopedLibrary()` registering with `PHPhotoLibrary`) was resolved by the Phase 1 W6 fix — `PhotoKitLibrary.init()` no longer registers observers. The remaining concern is wasteful re-instantiation of `PHCachingImageManager` across render passes, which is a performance/architecture issue. Phase 3 scope covers deduplication of grid architecture and the `getScopedLibrary()` pattern.

---

## New concurrency issues surfaced by re-verify

### N1 — PhotoLibraryChangePublisher declares Sendable but holds unprotected mutable state [SEVERITY: medium]
- **File:** SwipeSort/Core/PhotoLibraryChangePublisher.swift:18, 31
- **What:** `PhotoLibraryChangePublisher` is declared `final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, Sendable` (line 18) — plain `Sendable`, not `@unchecked Sendable` — while holding `private var isRegistered = false` (line 31). Under Swift 6 strict concurrency a `final class` with a `var` stored property cannot satisfy `Sendable` without actor isolation or `@unchecked`. The current code compiles under Swift 5 concurrency mode (where this generates a warning or is silently accepted for `NSObject` subclasses), but is unsound and will be a hard error under Swift 6.
- **Failure scenario:** Any future call to `register()` from a non-`@MainActor` context — e.g., if `SwipeSessionModel.start()` is ever called from a detached task — would race on `isRegistered` against another `register()` call on the main actor: both would read `isRegistered == false`, both would pass the guard, and both would call `PHPhotoLibrary.shared().register(self)`, registering the observer twice. The idempotency guarantee in the doc comment is enforced only by the call-site convention that `start()` is `@MainActor`, not by the type system.
- **Fix direction:** Replace `Sendable` with `@unchecked Sendable` and add a code comment documenting that `isRegistered` is accessed exclusively from `@MainActor`-isolated callers (`SwipeSessionModel.start()`), making the `@unchecked` opt-out justified. Alternatively, if `register()` is annotated `@MainActor` (safe — the only caller is `@MainActor`), the compiler can verify that `isRegistered` is always accessed on the main actor. Note: the class cannot be made fully `@MainActor` because `photoLibraryDidChange(_:)` is called by PhotoKit from a background thread and must remain non-isolated.

### N2 — DecisionQueue lacks @MainActor isolation annotation despite being accessed exclusively through @MainActor SwipeSessionModel [SEVERITY: low]
- **File:** SwipeSort/Core/SwipeDecision.swift:38
- **What:** `DecisionQueue` is `@Observable final class` with no actor isolation. It has eight stored `var` properties (`decisions`, `movedToAlbumCount`, `favoritedIds`, plus computed properties) that are mutated by `record`, `undoLast`, `removeDecision`, `removeCommitted`, and `markFavorited`. In production, all of these are called exclusively through `@MainActor SwipeSessionModel`. Under Swift 6 strict concurrency, an `@Observable` class without actor isolation whose stored properties are mutated from a `@MainActor` context generates a warning because the observation registrar accesses are unguarded.
- **Failure scenario:** No active race today because `SwipeSessionModel` is `@MainActor` and `queue` is accessed as a `let` property through that isolation. However, `DeletionQueueView` reads `model.queue.decisions` from a SwiftUI view body — safe because SwiftUI views render on the main thread, but Swift 6's strict checking would flag the `@Observable` property observation as potentially off-actor if `DecisionQueue` is not isolated. A test that constructs and drives `DecisionQueue` directly off the main actor (without going through `SwipeSessionModel`) could observe torn state.
- **Fix direction:** Add `@MainActor` to `DecisionQueue`. This is a small annotation, aligns with the existing usage pattern, and makes the isolation explicit rather than relying on a documentation-only convention. `DeletionQueueView`'s read of `model.queue.decisions` is already main-actor-safe and requires no change.

---

## Recommended fix order

1. **W1 — Add `@MainActor` to `PhotoKitLibrary`, remove `@unchecked Sendable`** — the highest-severity item and the blocker for W2. Also update `PhotoLibraryProviding`'s threading comment to document the `@MainActor` requirement on the concrete implementation. Since `WindowedThumbnailCache` (also `@MainActor`) calls `startCachingThumbnails`/`stopCachingThumbnails` synchronously, these calls remain synchronous and require no protocol changes.

2. **W2 — Add `@MainActor` to `MockPhotoLibrary`, remove `@unchecked Sendable`** — depends on W1 to confirm the isolation choice. Must land in the same PR so the test suite does not temporarily have an inconsistent conformance (one isolated, one not). Update the threading note in the class doc comment.

3. **N1 — Fix PhotoLibraryChangePublisher Sendable claim** — independent of W1/W2. Small one-line change: annotate `register()` as `@MainActor` (enforces that `isRegistered` is only accessed from the main actor) and keep the class `@unchecked Sendable` (justified because `photoLibraryDidChange` is called from a background thread and the mutable state is only `isRegistered`, which is protected by the `@MainActor` annotation on `register()`). This turns a documentation-only invariant into a compiler-checked one.

4. **N2 — Add `@MainActor` to `DecisionQueue`** — low-severity, fully independent. Land as an addendum to the W2 PR or as a standalone cleanup commit. No callers need changes because all callers are already `@MainActor`.

Independence note: W1 and W2 must land atomically (same commit or same PR) because splitting them would leave `MockPhotoLibrary` out of conformance with `PhotoLibraryProviding` between the two changes. N1 and N2 are independent of each other and of W1/W2.

---

## Testing follow-ups (Phase 5 input)

- Verify that `PhotoKitLibrary` compiles under Swift 6 strict concurrency mode (`SWIFT_STRICT_CONCURRENCY = complete`) with no warnings or errors after the `@MainActor` annotation is added (W1 regression: confirms `@unchecked Sendable` is fully removed).
- Verify that `MockPhotoLibrary` compiles under Swift 6 strict concurrency mode after `@MainActor` annotation (W2 regression).
- Test that `PhotoLibraryChangePublisher.register()` annotated `@MainActor` can be called from a `@MainActor` test context without await, and that calling it twice in the same test does not double-register (N1 regression: idempotency under single-actor access).
- Test `DecisionQueue` mutation methods (`record`, `undoLast`, `removeCommitted`) from a `@MainActor` test context to confirm the isolation annotation does not break the existing `SwipeDecisionQueueTests` suite (N2 regression).
- Test that `WindowedThumbnailCache.slide()` called from a `Task {}` (no explicit actor) still executes on the main actor and does not observe stale `currentWindow` — can be verified by asserting `startCachingCalls.count` after two rapid `slide()` calls on `MockPhotoLibrary` (F15 confirmation that the @MainActor fix is stable post-W1/W2 changes).
