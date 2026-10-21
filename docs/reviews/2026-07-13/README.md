# SwipeSort Review — 2026-07-13

> [!NOTE]
> **Status: ALL 7 PHASES COMPLETED (All 105 findings resolved)**  
> This document records the historical audit conducted on 2026-07-13. All 105 findings across correctness, concurrency, architecture, performance, testing, accessibility, and cleanup have been remediated in the completed 7-phase fix roadmap (see [`PHASES.md`](./PHASES.md)).

## Overview

This review covers the full SwipeSort iOS/SwiftUI codebase as of 2026-07-13 across six parallel lens subagents (correctness, architecture, performance, testing, best-practices, cleanup), each followed by an adversarial verify pass that downgraded or refuted overclaimed findings. One finding (performance F1, the "main-actor stall" claim for `loadCurrent`) was fully refuted and removed. The 105 surviving findings span 0 critical, 25 high, 51 medium, and 29 low items. The dominant pattern is a cluster of interacting correctness bugs in `SwipeSessionModel`'s decision-lifecycle state machine — double-execution of album moves, an early-exit guard that ignores move-only sessions, and an unconditional `phase = .finished` transition on commit cancellation — that together create a range of misleading UI states and a structural trap for future refactors. A secondary cluster is architectural duplication: the grid body and selection infrastructure are copied verbatim between `RecentsView` and `AlbumGridView` and their shared primitives are stranded inside semantically unrelated files. Testing coverage is strong on happy paths but has no scaffolding for the failure modes the correctness bugs expose (commit cancellation, mid-session library refresh, auth revocation). Accessibility is largely absent from the core swipe UI.

## Lens summary

| Lens | Findings | Critical | High | Medium | Low |
|------|----------|----------|------|--------|-----|
| Correctness | 18 | 0 | 7 | 10 | 1 |
| Architecture | 14 | 0 | 4 | 7 | 3 |
| Performance | 13 | 0 | 5 | 6 | 2 |
| Testing | 20 | 0 | 5 | 8 | 7 |
| Best Practices | 20 | 0 | 1 | 13 | 6 |
| Cleanup | 20 | 0 | 3 | 7 | 10 |
| **Total** | **105** | **0** | **25** | **51** | **29** |

## Top 10 findings across all lenses

### 1. `swipeUp` double-executes album move — HIGH
- **From:** [correctness.md — F1](./correctness.md)
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:98
- **One-liner:** `swipeUp(intoAlbumId:)` calls `library.moveAssets(...)` directly and also records a `.moveToAlbum` decision in the queue, so any future path that commits moves will execute the operation a second time and `movedToAlbumCount` is permanently inflated on the finished summary.
- **Impact:** Re-executing a deferred move on the same asset causes a duplicate album membership or error surfaced to the user, and today's sessions already display an inflated "Moved to Album" count after commit.

### 2. `commitDecisions()` exits early when no deletions exist, skipping unflushed move decisions — HIGH
- **From:** [correctness.md — F2](./correctness.md)
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:239
- **One-liner:** `commitDecisions()` returns `.success(affectedCount: 0)` and sets `phase = .finished` immediately when `pendingDeletions` is empty, without processing any `.moveToAlbum` entries that might remain in the queue.
- **Impact:** Move-only sessions unconditionally transition to `.finished`, triggering auto-commit paths, and if F1 is fixed by deferring moves this early exit silently drops all pending album moves.

### 3. `PhotoKitLibrary` is `@unchecked Sendable` with unsynchronised mutable state — HIGH
- **From:** [correctness.md — F3](./correctness.md); also [best-practices.md — F1](./best-practices.md)
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:18
- **One-liner:** `fetchResult`, `fetchedAuth`, and `activeFilter` are mutable instance variables on a class marked `@unchecked Sendable` with no lock or actor isolation, allowing concurrent async callers to race on these fields.
- **Impact:** A background `refreshFetchResult()` triggered by `PhotoLibraryChangePublisher` while a session is loading can produce a stale empty `fetchResult`, yielding `totalCount = 0` or wrong asset identifiers on a 50k-asset library.

### 4. `undo()` silently navigates to index 0 when the undone asset is not found — HIGH
- **From:** [correctness.md — F4](./correctness.md)
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:182
- **One-liner:** When the backward scan in `undo()` fails to locate the popped identifier, `target` stays at its initialised value of `0`, so `currentIndex` jumps to the very first photo in the library rather than aborting or emitting a recoverable error.
- **Impact:** After an external iCloud deletion while the queue is open, tapping Undo silently jumps the user to photo #1, placing them at a completely wrong position in a library they have already partially reviewed.

### 5. `commitDecisions()` sets `phase = .finished` unconditionally before the system delete prompt is answered — HIGH
- **From:** [correctness.md — F6](./correctness.md)
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:246
- **One-liner:** `phase = .finished` is set unconditionally before the result of `library.commitDeletions` is evaluated; when the user cancels the iOS system alert, `phase` is permanently `.finished` even though deletions remain pending.
- **Impact:** The user cancels the system deletion prompt, the queue is preserved (correct) but the UI is stuck on the finished screen with no path to retry — deletions are effectively stranded until the session is restarted.

### 6. `DecisionQueue.removeCommitted()` only strips `.delete`; stale `.moveToAlbum` decisions accumulate indefinitely — HIGH
- **From:** [correctness.md — F8](./correctness.md)
- **File:** SwipeSort/Core/SwipeDecision.swift:70
- **One-liner:** After a successful commit, `removeCommitted()` deletes only `.delete` decisions; `.moveToAlbum` entries are never removed, causing `movedToAlbumCount` to grow unboundedly across repeated commit calls.
- **Impact:** A second `commitDecisions()` call after F1 is fixed would re-execute all previously-committed album moves, and today's multi-batch sessions already show inflated "Moved to Album" counts in the finished summary.

### 7. `PhotoLibraryChangePublisher.register()` is called from `PhotoKitLibrary.init()` before authorization is granted — HIGH
- **From:** [correctness.md — F9](./correctness.md)
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:28
- **One-liner:** `PhotoLibraryChangePublisher.shared.register()` calls `PHPhotoLibrary.shared().register(self)` inside `init()`, which runs before the user has granted library access, directly contradicting the docstring that says "Call once after photo-library access is granted."
- **Impact:** On first launch the observer is registered without authorization; if access is later denied the observer still fires on any library change, triggering unnecessary `loadAssets()` / `loadAlbums()` re-indexing calls against an invalid fetch cursor.

### 8. Shared grid infrastructure trapped inside `AlbumPickerSheet.swift` — HIGH
- **From:** [architecture.md — F1](./architecture.md)
- **File:** SwipeSort/Features/Landing/AlbumPickerSheet.swift:151–199
- **One-liner:** `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, and `gridIndex` are defined inside the album-picker sheet file but are consumed by `RecentsView` and `AlbumGridView`; any future grid consumer must reach into a sheet implementation file to import shared primitives.
- **Impact:** A developer adding a third grid view who does not know to look in `AlbumPickerSheet.swift` will duplicate these types, creating two independent `GridCellFramePreferenceKey` implementations with silently diverging `reduce` logic in the preference graph.

### 9. `AlbumGridView` fully duplicates the `RecentsView` grid+selection body — HIGH
- **From:** [architecture.md — F2](./architecture.md)
- **File:** SwipeSort/Features/Landing/AlbumsView.swift:119–326 and SwipeSort/Features/Landing/RecentsView.swift:53–255
- **One-liner:** `AlbumGridView` copies the full lazy-grid, drag-selection, and cell-frame preference loop from `RecentsView` with only minor differences; both own identical `@State` clusters and identical 60-line drag gesture bodies.
- **Impact:** A one-sided fix has already occurred — `ThumbnailCell-\(index)` accessibility identifiers exist only in `RecentsView`, so UI tests targeting the Albums tab silently miss cells; any future bug fix or feature must be applied in two files.

### 10. `PhotoLibraryProviding` is a monolithic 22-method protocol — HIGH
- **From:** [architecture.md — F3](./architecture.md)
- **File:** SwipeSort/Core/PhotoLibraryProviding.swift:51–132
- **One-liner:** The 22-method protocol bundles authorization, read-only fetch, thumbnails, mutations, caching management, live-photo/video fetch, filter, and scoping into a single conformance that every consumer — including pure read-only grid views — must fully satisfy.
- **Impact:** `MockPhotoLibrary` must implement all 22 methods even when only 5 are exercised by a given test, and the compiler cannot flag a grid view accidentally calling `commitDeletions` because the type permits it; each new mutating method forces updates across all mocks and all consumers simultaneously.

## Triage table

User delegated triage: **all 105 findings accepted**. Execution plan is phase-by-phase — see [`PHASES.md`](./PHASES.md). Top-10 mapping to phases below.

| # | Finding | Accept? | Phase |
|---|---------|---------|-------|
| 1 | `swipeUp` double-executes album move | [x] accept | Phase 1 |
| 2 | `commitDecisions()` exits early, skipping move decisions | [x] accept | Phase 1 |
| 3 | `PhotoKitLibrary` @unchecked Sendable with unsynchronised state | [x] accept | Phase 2 |
| 4 | `undo()` silently navigates to index 0 on not-found | [x] accept | Phase 1 |
| 5 | `phase = .finished` set unconditionally before commit result | [x] accept | Phase 1 |
| 6 | `removeCommitted()` only strips `.delete` decisions | [x] accept | Phase 1 |
| 7 | `register()` called before authorization is granted | [x] accept | Phase 1 |
| 8 | Shared grid infrastructure trapped in `AlbumPickerSheet.swift` | [x] accept | Phase 3 |
| 9 | `AlbumGridView` duplicates `RecentsView` grid body verbatim | [x] accept | Phase 3 |
| 10 | `PhotoLibraryProviding` is a monolithic 22-method protocol | [x] accept | Phase 3 |

## How to proceed
Roadmap lives in [`PHASES.md`](./PHASES.md). Each phase runs: re-verify → plan → execute → user ack → next phase. Phase 1 (decision-lifecycle correctness) is starting now.

## Doc-pass verify

| Batch | Files | Verdict | Notes |
|-------|-------|---------|-------|
| A — Core types           | 7 | pass | All `///` blocks accurate; attributes, signatures, literals, and declaration order unchanged. |
| B — Core implementations | 4 | pass | All `///` blocks accurate; attributes, signatures, literals, and declaration order unchanged. |
| C — Swipe feature        | 7 | pass | All `///` blocks accurate; attributes, signatures, literals, and declaration order unchanged. |
| D — Landing feature      | 7 | pass | All `///` blocks accurate; attributes, signatures, literals, and declaration order unchanged. |
| E — Settings + app root  | 3 | pass | All `///` blocks accurate; attributes, signatures, literals, and declaration order unchanged. |
