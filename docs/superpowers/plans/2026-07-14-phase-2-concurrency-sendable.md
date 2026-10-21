# Phase 2 — Concurrency + Sendable Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `@MainActor` isolation to `DecisionQueue`, `PhotoLibraryChangePublisher.register()`, `PhotoKitLibrary`, and `MockPhotoLibrary`, and tighten `Sendable` conformances to eliminate `@unchecked` where it is no longer justified.

**Architecture:** All four changes are annotation-only; no method signatures change, no logic moves. `DecisionQueue` and `PhotoKitLibrary`/`MockPhotoLibrary` gain `@MainActor` at the class level. `PhotoLibraryChangePublisher.register()` gains `@MainActor` at the method level (the class stays `@unchecked Sendable` because `photoLibraryDidChange` must remain non-isolated). The `@unchecked Sendable` conformances on `PhotoKitLibrary` and `MockPhotoLibrary` are removed entirely — a `@MainActor final class` satisfies `Sendable` by construction under Swift's actor-isolation rules.

**Tech Stack:** Swift 5 mode, SwiftUI, PhotoKit, Swift Testing.

**Working set:** [`docs/reviews/2026-07-13/phase-2-working-set.md`](../../reviews/2026-07-13/phase-2-working-set.md)

## Global Constraints

- Swift 6 language mode is NOT enabled in this project; targets Swift 5 mode with minimum iOS 17 deployment. Every change must compile cleanly under Swift 5 mode; Swift 6 is not required to build.
- Do NOT change `PhotoLibraryProviding` method signatures to `async` — real PhotoKit APIs called synchronously (`startCachingImages`, `stopCachingImages`) would break.
- Do NOT introduce a full `actor` isolation on `PhotoKitLibrary` — the sync-protocol constraint above forbids it. `@MainActor` is the chosen mechanism.
- All PhotoKit types are Objective-C bridged and inherently main-thread-affine; adding `@MainActor` formalizes existing runtime behavior.
- No git available in this environment — the human runs Xcode; every "run test" step is treated as a spec ("Expected: PASS"), the human executes.
- Test framework is Swift Testing (`import Testing`, `@Test`, `#expect`).
- All new tests go under `SwipeSortTests/` following existing file organization.

---

## Task ordering rationale

**N2 → N1 → W1 → W2**

- **N2 first** (`DecisionQueue`): smallest change, fully independent, zero risk of cascading failures. Good warm-up that validates the test cycle works before touching PhotoKit.
- **N1 second** (`PhotoLibraryChangePublisher.register()`): also independent of W1/W2, and small. The `@MainActor` annotation on `register()` is the counterpart to W1's `@MainActor` on the library — placing it before W1 means the publisher side is already sound when the library side lands.
- **W1 third** (`PhotoKitLibrary`): the design decision anchor. W2 must mirror it.
- **W2 last** (`MockPhotoLibrary`): must mirror W1 exactly. Landing W2 immediately after W1 keeps the protocol conformance consistent — never a state where the real impl is `@MainActor` but the mock is not.

W1 and W2 must land atomically (same commit, same PR) or in immediate succession within the same branch session, because any intermediate state where `PhotoKitLibrary` is `@MainActor` but `MockPhotoLibrary` is not would leave the test suite with an isolation mismatch against the `PhotoLibraryProviding` protocol.

---

## Task 1: N2 — Add `@MainActor` to `DecisionQueue`

**Files:**
- Modify: `SwipeSort/Core/SwipeDecision.swift` (line 37 — the `@Observable` annotation line)
- Test: `SwipeSortTests/SwipeDecisionQueueTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `DecisionQueue` is `@MainActor`-isolated. `SwipeSessionModel` (already `@MainActor`) accesses it through `let queue = DecisionQueue()` with no change needed. `DeletionQueueView` reads `model.queue.decisions` from a SwiftUI body — already main-actor-safe.

**TDD form:** The isolation change is compile-time. The test adds a `@MainActor`-context assertion inside a `DecisionQueue` method call to pin that `@MainActor`-isolated callers can call `DecisionQueue` methods synchronously (no `await` required). The test will compile today and continue to compile after the change; the assertion documents the invariant. A separate test drives `DecisionQueue` mutation methods from a `@MainActor` test context and confirms none of the existing tests regress.

- [ ] **Step 1: Write the regression test**

Open `SwipeSortTests/SwipeDecisionQueueTests.swift`. After the last existing test, add:

```swift
@Test("DecisionQueue mutation methods are callable synchronously from @MainActor context")
@MainActor
func decisionQueueCallableOnMainActor() {
    // This test is a compile-time + runtime isolation pin. It verifies:
    // 1. All DecisionQueue mutation methods are callable without `await` from a @MainActor context.
    // 2. Thread.isMainThread is true at the call site, confirming main-actor execution.
    let q = DecisionQueue()
    #expect(Thread.isMainThread, "DecisionQueue must be accessed on the main thread")
    q.record(.keep(AssetIdentifier("iso-test-1")))
    q.record(.delete(AssetIdentifier("iso-test-2")))
    q.record(.moveToAlbum(AssetIdentifier("iso-test-3"), fromAlbumId: nil, toAlbumId: "alb-iso"))
    #expect(q.decisions.count == 3)
    #expect(q.movedToAlbumCount == 1)
    q.markFavorited(AssetIdentifier("iso-test-1"))
    #expect(q.favoritedCount == 1)
    let popped = q.undoLast()
    #expect(popped == .moveToAlbum(AssetIdentifier("iso-test-3"), fromAlbumId: nil, toAlbumId: "alb-iso"))
    #expect(q.movedToAlbumCount == 0)
    q.removeCommitted()
    // After removeCommitted() strips .delete entries, only .keep("iso-test-1") remains.
    #expect(q.decisions.count == 1)
    #expect(q.keepCount == 1)
    #expect(q.deleteCount == 0)
}
```

Note: `SwipeDecisionQueueTests` does not currently have `@MainActor` on the struct. Adding it to this single test function (not the struct) is sufficient. Alternatively, if the struct already has `@MainActor` after W1/W2 land in the same session, this test merges cleanly.

- [ ] **Step 2: Run the test to confirm it compiles and passes today (regression anchor)**

In Xcode: Product → Test → filter to `SwipeDecisionQueueTests/decisionQueueCallableOnMainActor`.

Expected: **PASS** — `DecisionQueue` is not yet `@MainActor`, but the test is `@MainActor`-annotated so it runs on the main actor, which means `Thread.isMainThread` is true and the calls succeed. This confirms the test is a valid anchor before and after the annotation change.

- [ ] **Step 3: Add `@MainActor` to `DecisionQueue`**

In `SwipeSort/Core/SwipeDecision.swift`, replace lines 37–38:

```swift
// BEFORE (lines 37–38)
@Observable
final class DecisionQueue {
```

```swift
// AFTER
@Observable
@MainActor
final class DecisionQueue {
```

No other changes to `SwipeDecision.swift` are needed. The doc comment at lines 27–36 already says "The queue is the authoritative source of truth…"; update just the threading line in the class body comment at the top of the `@Observable` block. Replace the existing class-level comment (lines 27–36):

```swift
// BEFORE (lines 27–36)
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
```

```swift
// AFTER
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
///
/// Threading: `@MainActor`-isolated (N2 fix). All production callers go through
/// `@MainActor SwipeSessionModel`. `DeletionQueueView` reads `decisions` from a
/// SwiftUI body, which also runs on the main actor. No callers need `await` to
/// call mutation methods.
```

- [ ] **Step 4: Run all DecisionQueue and SwipeSessionModel tests**

In Xcode: Product → Test → filter to `SwipeDecisionQueueTests` and `SwipeSessionModelTests`.

Expected: all tests **PASS**. If the compiler emits a warning about `@MainActor`-isolated access from a non-isolated context in any test file, wrap that test's struct or function with `@MainActor`.

- [ ] **Step 5: Commit**

```
git add SwipeSort/Core/SwipeDecision.swift \
        SwipeSortTests/SwipeDecisionQueueTests.swift
git commit -m "phase-2: add @MainActor to DecisionQueue, pin isolation in test — N2"
```

---

## Task 2: N1 — Fix `PhotoLibraryChangePublisher` `Sendable` + annotate `register()` `@MainActor`

**Files:**
- Modify: `SwipeSort/Core/PhotoLibraryChangePublisher.swift` (line 18 — class declaration; line 41 — `register()` signature)
- Test: `SwipeSortTests/SwipeSessionModelTests.swift` (the existing `PhotoLibraryChangePublisherTests` suite at line 458)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `PhotoLibraryChangePublisher` is `@unchecked Sendable` (justified — see comment); `register()` is `@MainActor`. `SwipeSessionModel.start()` (line 89 of `SwipeSessionModel.swift`) calls `PhotoLibraryChangePublisher.shared.register()` from a `@MainActor` context — this call is already main-actor-isolated and does not need `await`.

**TDD form:** The existing `registerIsIdempotent` test at `SwipeSessionModelTests.swift:461` already pins call-site behavior. The regression test added here pins that `register()` is callable from a `@MainActor` context without `await`, and that the idempotency guard holds. Because `register()` will gain `@MainActor`, calling it from a non-`@MainActor` context becomes a compile error — this is the compile-time safety the fix provides.

- [ ] **Step 1: Write the regression test**

The `PhotoLibraryChangePublisherTests` struct (line 458 of `SwipeSessionModelTests.swift`) currently has no `@MainActor`. Add a second test to the suite:

```swift
// Add inside the existing PhotoLibraryChangePublisherTests struct,
// after the existing registerIsIdempotent test (after line 475):

@Test("register() is callable from @MainActor context without await")
@MainActor
func registerCallableOnMainActorWithoutAwait() {
    // Compile-time pin: after the @MainActor annotation is added to register(),
    // calling it from a @MainActor context requires no `await`. If this test
    // file compiles and this call is not marked `await`, the isolation is correct.
    // Runtime pin: Thread.isMainThread must be true here.
    #expect(Thread.isMainThread, "register() must be callable from main actor")
    PhotoLibraryChangePublisher.shared.register()
    // If we reach here, register() is callable synchronously on the main actor.
    #expect(Bool(true))
}
```

This test will **PASS before the code change** (calling `register()` from `@MainActor` is fine today — the method is not yet annotated) and **continue to PASS after** (because `@MainActor register()` called from `@MainActor` is synchronous).

- [ ] **Step 2: Run the test to confirm it passes today (regression anchor)**

In Xcode: Product → Test → filter to `PhotoLibraryChangePublisherTests/registerCallableOnMainActorWithoutAwait`.

Expected: **PASS**.

- [ ] **Step 3: Apply the two changes to `PhotoLibraryChangePublisher.swift`**

**3a — Line 18: change `Sendable` to `@unchecked Sendable`**

```swift
// BEFORE (line 18)
final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, Sendable {
```

```swift
// AFTER (line 18)
// @unchecked Sendable is justified: the only mutable stored property is
// `isRegistered`, which is written exclusively from `@MainActor`-isolated
// callers (register() below). `photoLibraryDidChange(_:)` is called by
// PhotoKit on a background thread but reads no stored state — it only posts
// to NotificationCenter. The combination of @MainActor on the write path and
// read-only access on the background path makes the unsynchronised access safe.
final class PhotoLibraryChangePublisher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
```

**3b — Line 41: add `@MainActor` to `register()`**

```swift
// BEFORE (lines 35–45)
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

```swift
// AFTER (lines 35–46)
    /// Registers this observer with `PHPhotoLibrary`.
    ///
    /// Safe to call more than once — subsequent calls are no-ops. Must be called
    /// only after photo-library access is granted (`.authorized` or `.limited`).
    /// Calling before authorization is confirmed may trigger spurious
    /// `photoLibraryDidChange` callbacks against an invalid fetch cursor (W6 fix).
    ///
    /// `@MainActor` ensures `isRegistered` is only written on the main actor,
    /// making the `@unchecked Sendable` opt-out on the class sound (N1 fix).
    /// The sole caller (`SwipeSessionModel.start()`) is `@MainActor`-isolated.
    @MainActor
    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        PHPhotoLibrary.shared().register(self)
    }
```

- [ ] **Step 4: Run the PhotoLibraryChangePublisher tests and all session model tests**

In Xcode: Product → Test → filter to `PhotoLibraryChangePublisherTests` and `SwipeSessionModelTests`.

Expected: all tests **PASS**. The `register()` call in `SwipeSessionModel.start()` at line 89 is already within a `@MainActor` context — no `await` needed, no source change required there.

- [ ] **Step 5: Commit**

```
git add SwipeSort/Core/PhotoLibraryChangePublisher.swift \
        SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "phase-2: @unchecked Sendable + @MainActor register() on PhotoLibraryChangePublisher — N1"
```

---

## Task 3: W1 — Add `@MainActor` to `PhotoKitLibrary`, remove `@unchecked Sendable`

**Files:**
- Modify: `SwipeSort/Core/PhotoKitLibrary.swift` (line 27 — class declaration; lines 7–26 — threading note in doc comment)
- Modify: `SwipeSort/Core/PhotoLibraryProviding.swift` (lines 64–67 — threading comment in the protocol doc)
- Test: `SwipeSortTests/MockPhotoLibraryTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (W1 is independent of N1/N2).
- Produces: `PhotoKitLibrary` is `@MainActor final class`. `@unchecked Sendable` is removed; the class satisfies `Sendable` implicitly through actor isolation. `WindowedThumbnailCache` (also `@MainActor`) calls `startCachingThumbnails`/`stopCachingThumbnails` synchronously — these remain synchronous instance methods with no `async` or `await` required.

**TDD form:** A `@MainActor`-context test calls `PhotoKitLibrary`'s synchronous methods and asserts `Thread.isMainThread`. Because `PhotoKitLibrary` requires a real device to exercise most paths (and tests run on a simulator without a real photo library), the test is written against the `MockPhotoLibrary` conformance — this verifies the protocol surface. A separate compile-time anchor test, placed in `MockPhotoLibraryTests.swift`, constructs a `PhotoKitLibrary`-shaped value from the protocol type and confirms the `Sendable` conformance holds.

**Important caller check:** The two callers that matter are:
1. `WindowedThumbnailCache` — already `@MainActor`. Calls `startCachingThumbnails`, `stopCachingThumbnails`, `stopCachingAllThumbnails`, and `identifiers(in:)` synchronously or via `await`. After W1, these are `@MainActor`-isolated method calls from a `@MainActor` caller — no change needed.
2. `SwipeSessionModel` — already `@MainActor`. All `async` calls to the `library` property go through `await` today — these continue to work because `@MainActor` is an actor-isolation boundary, and `await`-ing an `@MainActor` method from another `@MainActor` call site is a no-op hop.

No callers outside `@MainActor` context exist in the production code. The fix formalizes what is already true at runtime.

- [ ] **Step 1: Write the regression test**

In `SwipeSortTests/MockPhotoLibraryTests.swift`, add after the last test:

```swift
@Test("PhotoLibraryProviding synchronous caching methods are callable from @MainActor context without await")
@MainActor
func cachingMethodsCallableOnMainActor() {
    // This test pins that startCachingThumbnails and stopCachingThumbnails —
    // the two synchronous (non-async) protocol requirements — are callable from
    // @MainActor context without await. This is true before W1 (no isolation
    // annotation yet) and must remain true after W1 (@MainActor on the class
    // means these are @MainActor-isolated and callable synchronously from
    // another @MainActor context).
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    let ids = [AssetIdentifier("cache-test-0"), AssetIdentifier("cache-test-1")]
    let size = CGSize(width: 100, height: 100)

    #expect(Thread.isMainThread, "caching calls must be on the main thread")
    mock.startCachingThumbnails(ids, targetSize: size)
    mock.stopCachingThumbnails(ids, targetSize: size)
    mock.stopCachingAllThumbnails()

    #expect(mock.startCachingCalls.count == 1)
    #expect(mock.stopCachingCalls.count == 1)
    #expect(mock.stopAllCallCount == 1)
}
```

- [ ] **Step 2: Run the test to confirm it passes today (regression anchor)**

In Xcode: Product → Test → filter to `MockPhotoLibraryTests/cachingMethodsCallableOnMainActor`.

Expected: **PASS**.

- [ ] **Step 3: Apply the changes to `PhotoKitLibrary.swift`**

**3a — Replace the class-level doc comment and class declaration (lines 7–27)**

```swift
// BEFORE (lines 7–27)
/// Production `PhotoLibraryProviding` backed by PhotoKit.
///
/// The class owns a single `PHCachingImageManager` and a lazily-populated
/// `PHFetchResult<PHAsset>` cursor. The cursor is never materialised to an
/// array; callers read individual assets or contiguous index ranges through
/// `ensureFetchResult()`.
///
/// Threading note: this class is `@unchecked Sendable`. Three mutable
/// properties — `fetchResult`, `fetchedAuth`, and `activeFilter` — are not
/// protected by a lock or actor. All call sites today reach this class from
/// `@MainActor`-isolated code, so concurrent mutation does not occur in
/// practice; however, any future detached-task call site that writes these
/// properties without coordination would introduce a data race. Prefer
/// funnelling all calls through a `@MainActor` isolation boundary or
/// promoting this class to an `actor`.
///
/// PhotoKit invariant: every `requestImage` call uses pixel-scaled
/// `targetSize`, `.aspectFill` content mode, `.opportunistic` delivery
/// where appropriate, and `isNetworkAccessAllowed = true` so iCloud-only
/// assets are downloaded on demand.
final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable {
```

```swift
// AFTER (lines 7–27)
/// Production `PhotoLibraryProviding` backed by PhotoKit.
///
/// The class owns a single `PHCachingImageManager` and a lazily-populated
/// `PHFetchResult<PHAsset>` cursor. The cursor is never materialised to an
/// array; callers read individual assets or contiguous index ranges through
/// `ensureFetchResult()`.
///
/// Threading: `@MainActor`-isolated (W1 fix). The three mutable stored
/// properties — `fetchResult`, `fetchedAuth`, and `activeFilter` — are
/// protected by actor isolation rather than a lock. All production callers
/// (`SwipeSessionModel`, `WindowedThumbnailCache`) are `@MainActor`-isolated,
/// so no `await` is needed at call sites for synchronous methods. A full
/// `actor` upgrade was considered but rejected: the synchronous protocol
/// requirements `startCachingThumbnails` / `stopCachingThumbnails` cannot
/// be made `async` without breaking `WindowedThumbnailCache`'s calling
/// convention and the `PhotoLibraryProviding` protocol surface.
///
/// PhotoKit invariant: every `requestImage` call uses pixel-scaled
/// `targetSize`, `.aspectFill` content mode, `.opportunistic` delivery
/// where appropriate, and `isNetworkAccessAllowed = true` so iCloud-only
/// assets are downloaded on demand.
@MainActor
final class PhotoKitLibrary: PhotoLibraryProviding {
```

(`@unchecked Sendable` is removed entirely. A `@MainActor final class` satisfies `Sendable` by construction — the compiler enforces that crossing the actor boundary requires `await`, which makes unsynchronised concurrent access impossible.)

- [ ] **Step 4: Update the threading note in `PhotoLibraryProviding.swift`**

In `SwipeSort/Core/PhotoLibraryProviding.swift`, replace lines 64–67:

```swift
// BEFORE (lines 64–67)
/// Threading: all `async` requirements are safe to call from any isolation
/// context. `startCachingThumbnails` / `stopCachingThumbnails` must be
/// called from `@MainActor` — see those declarations.
protocol PhotoLibraryProviding: Sendable {
```

```swift
// AFTER (lines 64–67)
/// Threading: the concrete implementations (`PhotoKitLibrary`, `MockPhotoLibrary`)
/// are `@MainActor`-isolated. All callers must therefore be `@MainActor`-isolated
/// or cross the actor boundary with `await` for the `async` requirements.
/// The synchronous requirements `startCachingThumbnails`, `stopCachingThumbnails`,
/// and `stopCachingAllThumbnails` must be called from a `@MainActor` context
/// because the concrete implementations are `@MainActor`-isolated.
protocol PhotoLibraryProviding: Sendable {
```

- [ ] **Step 5: Run all tests**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. If any test file that constructs a `PhotoKitLibrary` or calls its methods from a non-`@MainActor` context emits a concurrency warning, wrap the relevant `@Test` function or `@Suite` struct with `@MainActor`.

Note: `MockPhotoLibraryTests` already has no `@MainActor` at the struct level — the new test added in Step 1 carries its own `@MainActor`. After W2 (next task) adds `@MainActor` to `MockPhotoLibrary`, the compiler will require that all tests accessing `MockPhotoLibrary` mutable state do so from the main actor. This is already satisfied because `MockPhotoLibraryTests` calls are `async` and Swift Testing runs `async` test functions on the main actor by default.

- [ ] **Step 6: Commit W1 (do not push — W2 must land in the same session)**

```
git add SwipeSort/Core/PhotoKitLibrary.swift \
        SwipeSort/Core/PhotoLibraryProviding.swift \
        SwipeSortTests/MockPhotoLibraryTests.swift
git commit -m "phase-2: @MainActor on PhotoKitLibrary, remove @unchecked Sendable — W1"
```

---

## Task 4: W2 — Add `@MainActor` to `MockPhotoLibrary`, remove `@unchecked Sendable`

**Files:**
- Modify: `SwipeSort/Core/MockPhotoLibrary.swift` (lines 7–19 — doc comment + class declaration)
- Test: `SwipeSortTests/MockPhotoLibraryTests.swift`

**Interfaces:**
- Consumes: Task 3 (W1) — the `@MainActor` isolation choice must be mirrored so `MockPhotoLibrary` conforms to `PhotoLibraryProviding` consistently with `PhotoKitLibrary`.
- Produces: `MockPhotoLibrary` is `@MainActor final class`. `@unchecked Sendable` is removed. All existing tests that drive `MockPhotoLibrary` through `SwipeSessionModel` (which is `@MainActor`) or directly from `@MainActor @Suite` test structs continue to work without change.

**TDD form:** The test adds a `@MainActor`-context assertion that confirms `MockPhotoLibrary` mutable properties are accessible synchronously from the main actor. This is the mirror of the `cachingMethodsCallableOnMainActor` test from W1.

- [ ] **Step 1: Write the regression test**

In `SwipeSortTests/MockPhotoLibraryTests.swift`, add after the last existing test:

```swift
@Test("MockPhotoLibrary mutable properties are accessible on the main actor without await")
@MainActor
func mockMutablePropertiesAccessibleOnMainActor() {
    // Compile-time + runtime pin: after @MainActor is added to MockPhotoLibrary,
    // all reads/writes of its stored properties must be from the main actor.
    // This test confirms the conformance is sound under @MainActor isolation.
    #expect(Thread.isMainThread, "MockPhotoLibrary must be accessed on main thread")
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    // Write mutable properties synchronously (no await).
    mock.seedAlbums([UserAlbum(id: "alb-ma", title: "Main Actor Album", assetCount: 0, canAdd: true)])
    mock.nextCommitResult = .cancelledByUser
    mock.scriptedMediaKinds["mock-asset-0"] = .livePhoto
    // Read them back synchronously.
    #expect(mock.appliedFilter == .unfiltered)
    #expect(mock.startCachingCalls.isEmpty)
    #expect(mock.stopCachingCalls.isEmpty)
    #expect(mock.stopAllCallCount == 0)
    // Call synchronous protocol methods.
    let ids = [AssetIdentifier("mock-asset-0")]
    mock.startCachingThumbnails(ids, targetSize: CGSize(width: 50, height: 50))
    #expect(mock.startCachingCalls.count == 1)
}
```

- [ ] **Step 2: Run the test to confirm it passes today (regression anchor)**

In Xcode: Product → Test → filter to `MockPhotoLibraryTests/mockMutablePropertiesAccessibleOnMainActor`.

Expected: **PASS**.

- [ ] **Step 3: Apply the changes to `MockPhotoLibrary.swift`**

**3a — Replace the class-level doc comment and class declaration (lines 7–19)**

```swift
// BEFORE (lines 7–19)
/// Deterministic in-memory `PhotoLibraryProviding` for tests and UI previews.
///
/// Generates solid-colour placeholder thumbnails derived from the asset
/// identifier's hash so view-model and UI tests can assert on image presence
/// without a real photo library.
///
/// Threading note: like `PhotoKitLibrary`, this class is `@unchecked Sendable`
/// while holding mutable state. All test-driven call sites are effectively
/// serial (Swift Testing runs test functions on the main actor by default),
/// so concurrent mutation does not occur in current tests. Any test that
/// exercises concurrent async paths should drive this class from a single
/// isolation context.
final class MockPhotoLibrary: PhotoLibraryProviding, @unchecked Sendable {
```

```swift
// AFTER (lines 7–19)
/// Deterministic in-memory `PhotoLibraryProviding` for tests and UI previews.
///
/// Generates solid-colour placeholder thumbnails derived from the asset
/// identifier's hash so view-model and UI tests can assert on image presence
/// without a real photo library.
///
/// Threading: `@MainActor`-isolated (W2 fix), mirroring `PhotoKitLibrary`.
/// Swift Testing runs `async` test functions on the main actor by default,
/// so `@MainActor` on `MockPhotoLibrary` adds zero runtime cost in tests while
/// making the conformance sound — all mutable stored properties are protected
/// by actor isolation rather than the previous documentation-only convention.
@MainActor
final class MockPhotoLibrary: PhotoLibraryProviding {
```

(`@unchecked Sendable` is removed. `@MainActor final class` satisfies `Sendable` by construction, consistent with `PhotoKitLibrary`.)

- [ ] **Step 4: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**.

If any test struct that drives `MockPhotoLibrary` synchronously (not through `await`) emits a concurrency warning, add `@MainActor` to that specific `@Test` function. The majority of tests go through `SwipeSessionModel` methods (`start()`, `swipeDelete()`, etc.) which are themselves `@MainActor async` — these automatically cross the actor boundary correctly.

Specifically verify:
- `MockPhotoLibraryTests` — the struct has no `@MainActor`; all tests are `async`. Expected: **PASS** (Swift Testing dispatches `async` tests on the main actor).
- `SwipeSessionModelTests` — struct is already `@MainActor`. Expected: **PASS**.
- `AlbumMoveTests` — struct is already `@MainActor`. Expected: **PASS**.
- `WindowedThumbnailCacheTests` — struct is already `@MainActor`. Expected: **PASS**.

- [ ] **Step 5: Commit W2**

```
git add SwipeSort/Core/MockPhotoLibrary.swift \
        SwipeSortTests/MockPhotoLibraryTests.swift
git commit -m "phase-2: @MainActor on MockPhotoLibrary, remove @unchecked Sendable — W2"
```

---

## Self-Review

### 1. Spec coverage

| Working-set item | Task | Status |
|---|---|---|
| N2 — `DecisionQueue` missing `@MainActor` | Task 1 | Covered |
| N1 — `PhotoLibraryChangePublisher` plain `Sendable` unsound; `register()` not `@MainActor` | Task 2 | Covered |
| W1 — `PhotoKitLibrary` `@unchecked Sendable` with unprotected mutable state | Task 3 | Covered |
| W2 — `MockPhotoLibrary` `@unchecked Sendable` with unprotected mutable state | Task 4 | Covered |

All 4 working-set items are covered. No gaps.

### 2. Placeholder scan

Scanned all tasks for "TBD", "TODO", "implement later", "fill in details", "add validation", "handle edge cases", "similar to Task N", steps without code.

- Task 1 Step 1 contains a comment `// Actually: removeCommitted strips .delete entries.` — this is an inline correction within the test body showing the developer's reasoning; it is actual test code, not a placeholder.
- Task 3 Step 4 instructs "if any test file emits a concurrency warning, wrap with `@MainActor`" — this is conditional guidance, not a deferred placeholder. The specific test suites that need checking are listed explicitly.
- No unresolved placeholders found.

### 3. Type consistency

- `DecisionQueue` gains `@MainActor` in Task 1. `SwipeSessionModel.queue` (`let queue = DecisionQueue()` at line 48 of `SwipeSessionModel.swift`) is accessed throughout the model's `@MainActor`-isolated methods — consistent, no call-site changes needed.
- `PhotoLibraryChangePublisher.register()` gains `@MainActor` in Task 2. The sole call site is `SwipeSessionModel.start()` at line 89, which is `@MainActor` — consistent.
- `PhotoKitLibrary` changes from `final class PhotoKitLibrary: PhotoLibraryProviding, @unchecked Sendable` to `@MainActor final class PhotoKitLibrary: PhotoLibraryProviding` in Task 3. The `WindowedThumbnailCache` (`@MainActor`) calls `library.startCachingThumbnails`, `library.stopCachingThumbnails`, `library.stopCachingAllThumbnails` — all synchronous, all `@MainActor`-to-`@MainActor`, consistent.
- `MockPhotoLibrary` mirrors `PhotoKitLibrary`'s declaration in Task 4. Both are `@MainActor final class` conforming to `PhotoLibraryProviding: Sendable` — consistent. No test references a type name that changed.
- `PhotoLibraryProviding` doc comment updated in Task 3 — no protocol signature changed. Consistent.

---

## Handoff

Plan saved to `/home/harshal.patil/Documents/SwipeSort/docs/superpowers/plans/2026-07-14-phase-2-concurrency-sendable.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task using `superpowers:subagent-driven-development`. Review between tasks. Fast iteration with isolated context per task.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`. Batch execution with checkpoints.

Which approach?
