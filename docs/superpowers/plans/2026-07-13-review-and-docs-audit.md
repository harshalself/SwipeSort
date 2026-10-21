# SwipeSort Review & Docs Audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a six-lens findings report on the SwipeSort codebase, then apply a doc-comment-only pass — with zero code-semantics changes in this cycle.

**Architecture:** Fan out six independent review subagents in parallel (one per lens), adversarially verify high/critical findings, synthesize a top-10 README, gate on user triage, then run a single doc-pass agent followed by a post-doc verify agent. Fixes for accepted findings are separate downstream plans.

**Tech Stack:** Swift 5.9+/6, SwiftUI, PhotoKit, Swift Testing. Plan work runs entirely in Markdown + subagent orchestration — no Xcode build in this environment.

**Spec:** [`docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md`](../specs/2026-07-13-review-and-docs-audit-design.md)

## Global Constraints

- No code semantics change in this phase — findings only. Doc pass modifies comments/whitespace, nothing else.
- No signature changes, no rewording of `@available`, `@objc`, macro args, or attribute lists (doc pass would break compilation).
- No git commits until the user reviews deliverables — leave files unstaged.
- No new features. No renaming public API. No new tests written in this phase (missing tests are findings, not code).
- Every finding follows the uniform format defined in the spec §4 (severity, file:line, what, failure scenario, suggested fix direction, verified).
- Severity rubric — critical / high / medium / low as defined in spec §4.
- Findings ranked most-severe first inside each file.
- Adversarial verify applies only to `high` and `critical` findings; lower severities skip.
- All review artifacts live under `docs/reviews/2026-07-13/`.
- All source files considered live under `SwipeSort/` and `SwipeSortTests/`.
- Working directory: `/home/harshal.patil/Documents/SwipeSort/`.
- This is a non-git-tracked directory (`Is a git repository: false`) — the "commit" steps below are `git add`/`git commit` only if the user runs `git init` first; otherwise they are file-save checkpoints.

---

## File Structure

Files created by this plan:

```
docs/reviews/2026-07-13/
├── correctness.md         # Lens 1 findings
├── architecture.md        # Lens 2 findings
├── performance.md         # Lens 3 findings
├── testing.md             # Lens 4 findings
├── best-practices.md      # Lens 5 findings
├── cleanup.md             # Lens 6 findings
└── README.md              # Synthesis + top-10 + triage table
```

Files modified by this plan (Task 9 only):

```
SwipeSort/**/*.swift       # Doc comments only — no code semantic changes
```

Each lens file is self-contained. The README is the entry point after all six lenses complete.

---

## Task 1: Scaffold the review folder and shared file map

**Files:**
- Create: `docs/reviews/2026-07-13/.file-map.md` (working reference; not a deliverable but every subagent will read it)

**Interfaces:**
- Consumes: nothing.
- Produces: `.file-map.md` — a tree of every Swift file under `SwipeSort/` and `SwipeSortTests/` with line counts, plus a one-line responsibility per file, so every lens subagent starts from the same map instead of re-listing files.

- [ ] **Step 1: Enumerate every Swift file with line counts**

Run:
```bash
find /home/harshal.patil/Documents/SwipeSort/SwipeSort /home/harshal.patil/Documents/SwipeSort/SwipeSortTests -type f -name '*.swift' -printf '%p\n' | sort | xargs wc -l
```

Expected: 30+ lines of `<count> <path>` output, one per file, ending with a total.

- [ ] **Step 2: Write `.file-map.md` with the tree + one-line responsibilities**

Content template (fill in the one-line responsibility for each file by reading its header comment or top declaration):

```markdown
# SwipeSort File Map — 2026-07-13

Every lens reviewer starts here. Do not re-list files; use this map.

## SwipeSort/
- `SwipeSortApp.swift` (22 lines) — @main App entry; owns AppSettings; applies theme mode.
- `Core/AppSettings.swift` (95 lines) — @Observable user prefs backed by UserDefaults.
- `Core/DryRunMode.swift` (31 lines) — developer kill-switch for destructive PhotoKit ops.
- `Core/MockPhotoLibrary.swift` (173 lines) — test double implementing PhotoLibraryProviding.
- `Core/PhotoKitLibrary.swift` (497 lines) — real PhotoKit implementation of PhotoLibraryProviding.
- `Core/PhotoLibraryChangePublisher.swift` (37 lines) — NotificationCenter bridge for PHPhotoLibraryChangeObserver.
- `Core/PhotoLibraryProviding.swift` (132 lines) — protocol surface all PhotoKit access flows through.
- `Core/PixelSize.swift` (13 lines) — points→pixels helper.
- `Core/SwipeDecision.swift` (76 lines) — SwipeDirection, SwipeDecision, DecisionQueue.
- `Core/SwipeFilter.swift` (151 lines) — load-time filter model.
- `Core/UserAlbum.swift` (13 lines) — album value type.
- `Core/VideoPlayerPool.swift` (74 lines) — AVPlayer reuse pool for video cards.
- `Core/WindowedThumbnailCache.swift` (93 lines) — windowed prefetch around currentIndex.
- `Features/MainTabView.swift` (41 lines) — root TabView; owns shared PhotoLibraryProviding.
- `Features/Landing/AlbumFilterSheet.swift` (59 lines) — sheet to hide albums from list.
- `Features/Landing/AlbumPickerSheet.swift` (199 lines) — album picker for bulk move.
- `Features/Landing/AlbumsView.swift` (326 lines) — albums list + AlbumGridView.
- `Features/Landing/BulkDeleteView.swift` (143 lines) — bulk delete confirmation flow.
- `Features/Landing/FilterSheet.swift` (117 lines) — filter UI backing SwipeFilter.
- `Features/Landing/RecentsView.swift` (352 lines) — recents grid + ThumbnailCell.
- `Features/Settings/AboutView.swift` (32 lines) — about screen.
- `Features/Settings/SettingsView.swift` (89 lines) — user prefs form.
- `Features/Swipe/FullResViewer.swift` (70 lines) — pinch-zoom modal.
- `Features/Swipe/LivePhotoCardView.swift` (78 lines) — Live Photo card.
- `Features/Swipe/ReviewCommitView.swift` (125 lines) — pre-commit review list.
- `Features/Swipe/SwipeCardView.swift` (96 lines) — card renderer.
- `Features/Swipe/SwipeSessionModel.swift` (326 lines) — @MainActor session driver.
- `Features/Swipe/SwipeStackView.swift` (649 lines) — top-level swipe UI.
- `Features/Swipe/VideoCardView.swift` (53 lines) — video card.

## SwipeSortTests/
- `AlbumMoveTests.swift`
- `AppSettingsTests.swift`
- `BulkDeleteTests.swift`
- `CommitDeletionsTests.swift`
- `DebugMenuTests.swift`
- `DryRunModeTests.swift`
- `MockPhotoLibraryTests.swift`
- `SessionResumeTests.swift`
- `SettingsIntegrationTests.swift`
- `SwipeDecisionQueueTests.swift`
- `SwipeFilterTests.swift`
- `SwipeSessionModelTests.swift`
- `WindowedThumbnailCacheTests.swift`
```

- [ ] **Step 3: Save the file**

Write to `/home/harshal.patil/Documents/SwipeSort/docs/reviews/2026-07-13/.file-map.md`.

Verify: `ls docs/reviews/2026-07-13/.file-map.md` returns the path.

---

## Task 2: Lens 1 — `correctness.md`

**Files:**
- Create: `docs/reviews/2026-07-13/correctness.md`

**Interfaces:**
- Consumes: `.file-map.md` from Task 1.
- Produces: findings file in the uniform format from spec §4.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort iOS/SwiftUI codebase for CORRECTNESS AND BUGS
ONLY. Your output is one Markdown file — no code changes.

Read first (in order):
1. docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md — the spec
   this review implements. Note §4 findings format and severity rubric.
2. docs/reviews/2026-07-13/.file-map.md — canonical file list. Do not re-list.
3. docs/RESEARCH.md and docs/superpowers/plans/README.md — locked design
   decisions and version roadmap.

Then review the following files with a correctness lens:
- SwipeSort/Core/SwipeDecision.swift
- SwipeSort/Core/AppSettings.swift
- SwipeSort/Core/DryRunMode.swift
- SwipeSort/Core/PhotoLibraryProviding.swift
- SwipeSort/Core/PhotoKitLibrary.swift
- SwipeSort/Core/MockPhotoLibrary.swift
- SwipeSort/Core/PhotoLibraryChangePublisher.swift
- SwipeSort/Core/WindowedThumbnailCache.swift
- SwipeSort/Core/VideoPlayerPool.swift
- SwipeSort/Core/SwipeFilter.swift
- SwipeSort/Features/Swipe/SwipeSessionModel.swift
- SwipeSort/Features/Swipe/SwipeStackView.swift
- SwipeSort/Features/Swipe/ReviewCommitView.swift
- SwipeSort/Features/Landing/RecentsView.swift
- SwipeSort/Features/Landing/AlbumsView.swift
- SwipeSort/Features/Landing/BulkDeleteView.swift

Look specifically for:
- Logic bugs (off-by-ones, wrong branches, wrong sentinel handling).
- Race conditions and actor/threading errors. Note MainActor hops in async
  chains and any place where a non-main task mutates observable state.
- PhotoKit misuse: PHAsset localIdentifier fragility across library changes,
  PHFetchResult stale after external mutation, iCloud fetch failure paths
  not surfaced, PHCachingImageManager start/stop asymmetry, batch delete
  cancellation handling, PHPhotoLibraryChangeObserver dispatch.
- Unhandled auth states — .restricted, .limited, .notDetermined mid-session,
  authorization dropping while a Task is in flight.
- Edge cases in SwipeSessionModel: undo walks after skips, prev-index
  searches through decided sets, advance past totalCount, initial-index
  resolution when initialAssetId is stale, undo of `.moveToAlbum` when
  fromAlbumId is nil (docs say it should be an add-only reverse — is it?).
- DecisionQueue invariants: duplicate identifiers, remove-committed leaving
  keep/move decisions, ordering after undoLast + record.
- Dry-run gating gaps — any destructive path that reaches PhotoKit while
  DryRunMode.isEnabled is true.
- Commit ordering when the user cancels the system delete prompt.

For each finding produce (verbatim template):

### F<N> — <one-line title> [SEVERITY: <critical|high|medium|low>]
- **File:** <path>:<line>
- **What:** <one-sentence defect statement>
- **Why it matters / failure scenario:** <concrete inputs → wrong output>
- **Suggested fix direction:** <approach only, no code>
- **Verified:** pending

Rank findings most-severe first. Cap total findings at 20 for readability;
group near-duplicates. If a code path is deliberately safe and looks buggy,
say so under Verified with a one-line justification and drop it.

Write the final file to:
docs/reviews/2026-07-13/correctness.md

Header:
# Correctness & Bugs
**Reviewer:** correctness-lens  **Date:** 2026-07-13  **Verify status:** pending

## Summary
<one paragraph — key patterns you saw across findings>

## Findings
<F1, F2, … in the template above>

Return the file path when done. Do not write any other files.
```

- [ ] **Step 2: Verify the file exists and is well-formed**

Run:
```bash
test -f docs/reviews/2026-07-13/correctness.md && grep -c '^### F' docs/reviews/2026-07-13/correctness.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

Leave the file on disk. No `git add` yet — the user reviews everything in Task 8.

---

## Task 3: Lens 2 — `architecture.md`

**Files:**
- Create: `docs/reviews/2026-07-13/architecture.md`

**Interfaces:**
- Consumes: `.file-map.md`.
- Produces: findings file in uniform format.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort codebase for ARCHITECTURE AND MODULARITY
ONLY. Your output is one Markdown file — no code changes.

Read first: the spec at docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md
and docs/reviews/2026-07-13/.file-map.md.

Review these areas with an architecture lens:
- Folder structure vs actual responsibilities. Is `Features/Landing/` really
  landing screens, or does it host cross-cutting grid infra?
- Feature coupling: RecentsView, AlbumsView, and AlbumGridView all define
  ThumbnailCell/grid gestures/selection state. Should there be a shared
  Components/ module? What's the interface?
- SwipeStackView.swift is 649 lines. Identify natural seams (header,
  card area, album grid, control bar, gesture, finished summary) and
  propose which live in their own files.
- PhotoKitLibrary.swift is 497 lines. Identify substructure (auth,
  fetching, thumbnails, mutations, caching, live/video, filter).
- PhotoLibraryProviding surface: currently 20+ methods. Should it split
  into ReadOnly / Mutating / Caching sub-protocols so consumers can
  depend on the narrowest surface? Give a concrete proposal.
- AppSettings sprawl: dryRunMode is dev-only per the locked decisions but
  now lives on AppSettings alongside user prefs. Should it split?
- MainTabView owns the PhotoLibraryProviding via @State — is that the right
  place, or should it be @Environment-injected?
- SwipeSessionModel: 326 lines, mixes fetch cursor, decision queue proxy,
  thumbnail preload, and undo/prev logic. Are those separable?

For each finding use the uniform template from spec §4. Rank most-severe
first. Cap at 20 findings.

Write to: docs/reviews/2026-07-13/architecture.md
Header:
# Architecture & Modularity
**Reviewer:** architecture-lens  **Date:** 2026-07-13  **Verify status:** pending

Return the file path when done.
```

- [ ] **Step 2: Verify the file exists and is well-formed**

Run:
```bash
test -f docs/reviews/2026-07-13/architecture.md && grep -c '^### F' docs/reviews/2026-07-13/architecture.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 4: Lens 3 — `performance.md`

**Files:**
- Create: `docs/reviews/2026-07-13/performance.md`

**Interfaces:**
- Consumes: `.file-map.md`.
- Produces: findings file in uniform format.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort codebase for PERFORMANCE AND MEMORY ONLY.
Your output is one Markdown file — no code changes.

Read first: the spec at docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md
and docs/reviews/2026-07-13/.file-map.md.

Focus on these files:
- SwipeSort/Core/PhotoKitLibrary.swift
- SwipeSort/Core/WindowedThumbnailCache.swift
- SwipeSort/Core/VideoPlayerPool.swift
- SwipeSort/Features/Landing/RecentsView.swift (GridImageCache + ThumbnailCell)
- SwipeSort/Features/Landing/AlbumsView.swift (AlbumGridView)
- SwipeSort/Features/Swipe/SwipeStackView.swift
- SwipeSort/Features/Swipe/SwipeSessionModel.swift
- SwipeSort/Features/Swipe/VideoCardView.swift
- SwipeSort/Features/Swipe/LivePhotoCardView.swift

Look specifically for:
- PHCachingImageManager start/stop pairing (unbalanced calls leak memory).
- WindowedThumbnailCache window size and slide semantics vs 50k-asset library.
- VideoPlayerPool drain policy — is drainOnDisappear tight enough? Any leaks
  across sheet dismissals?
- GridImageCache NSCache sizing (600 count, 80 MB) — realistic for 3× iPhones?
- MainActor contention: SwipeSessionModel.loadCurrent fires 4 parallel async
  library calls. Any of them serialize on the main actor unnecessarily?
- Thumbnail pixel-size choices: RecentsView 400×400, SwipeCard 400×600 —
  correct for 3× displays at rendered point size?
- iCloud fetch failure handling — .allowNetworkAccess, progress reporting.
- Preloading window vs memory pressure — what happens at index 40k with
  10k prefetches issued?
- Redundant `refreshFetchResult` + `applyFilter` call pairs in RecentsView.loadAssets
  and AlbumGridView.loadAssets. Are both needed each call?
- Library change observer: RecentsView and AlbumsView both re-run loadAssets
  on notification. Any debounce?
- SwipeStackView task blocks — do they cancel on view disappearance?

For each finding use the uniform template. Rank most-severe first. Cap at 20.

Write to: docs/reviews/2026-07-13/performance.md
Header:
# Performance & Memory
**Reviewer:** performance-lens  **Date:** 2026-07-13  **Verify status:** pending

Return the file path when done.
```

- [ ] **Step 2: Verify**

Run:
```bash
test -f docs/reviews/2026-07-13/performance.md && grep -c '^### F' docs/reviews/2026-07-13/performance.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 5: Lens 4 — `testing.md`

**Files:**
- Create: `docs/reviews/2026-07-13/testing.md`

**Interfaces:**
- Consumes: `.file-map.md`.
- Produces: findings file in uniform format.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort codebase for TEST COVERAGE AND EDGE CASES
ONLY. Your output is one Markdown file — no code changes and no new tests
in this phase (missing tests are findings, not code).

Read first: the spec at docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md
and docs/reviews/2026-07-13/.file-map.md.

Enumerate every file under SwipeSortTests/. For each, note:
- What it covers.
- Any obvious weakness in the test design (mocks that lie, asserting
  implementation instead of behavior, missing async cancellation coverage,
  no boundary/edge coverage).

Then identify missing scenarios:
- Empty library (assetCount 0) — swipe start flow.
- Denied auth mid-session.
- iCloud download failure at commit.
- Mid-session PHPhotoLibraryChangeObserver fires (identifiers shift).
- Orientation changes.
- Rapid swipe spam (queue integrity).
- Undo across a phase change (.ready → .finished → undo).
- Filter change mid-session — the doc says don't, is it enforced?
- UI test coverage of the 4-way gestures under both gesture modes.
- MockPhotoLibrary fidelity vs real PhotoKit: does it model localIdentifier
  disappearance, iCloud latency, batch delete cancel?
- moveToAlbum with fromAlbumId nil vs non-nil symmetry.
- Undo of moveToAlbum symmetry.

For each finding use the uniform template. Rank most-severe first. Cap at 20.

Write to: docs/reviews/2026-07-13/testing.md
Header:
# Test Coverage & Edge Cases
**Reviewer:** testing-lens  **Date:** 2026-07-13  **Verify status:** pending

Return the file path when done.
```

- [ ] **Step 2: Verify**

Run:
```bash
test -f docs/reviews/2026-07-13/testing.md && grep -c '^### F' docs/reviews/2026-07-13/testing.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 6: Lens 5 — `best-practices.md`

**Files:**
- Create: `docs/reviews/2026-07-13/best-practices.md`

**Interfaces:**
- Consumes: `.file-map.md`.
- Produces: findings file in uniform format.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort codebase for SWIFT AND APPLE BEST PRACTICES
ONLY. Your output is one Markdown file — no code changes.

Read first: the spec at docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md
and docs/reviews/2026-07-13/.file-map.md.

Focus areas:
- Swift 6 concurrency and Sendable correctness across PhotoLibraryProviding
  and its two implementations (PhotoKitLibrary, MockPhotoLibrary). Which
  properties should be nonisolated? Is the protocol correctly Sendable?
- @Observable vs @ObservationIgnored usage in AppSettings and models. Any
  property that mutates but is not read by SwiftUI (should be ignored)?
- @Bindable idioms in SettingsView.
- SwiftUI:
  - task(id:) cancellation — is view teardown clean?
  - .task { } without id: is stale-closure risk when captured state changes?
  - Environment propagation into .sheet, .fullScreenCover (they get a
    separate environment stack — is AppSettings actually available?).
  - PreferenceKey usage in RecentsView and AlbumGridView for cell frames —
    correctness and perf.
  - @MainActor boundaries: SwipeSessionModel is @MainActor, but library
    calls are async — any accidental serialization?
- HIG conformance for the swipe UI: 44pt tap targets, haptic patterns,
  dynamic type, reduce-motion, dark-mode contrast.
- Accessibility: VoiceOver labels on swipe card, drag hint overlay
  described (currently visual-only), pending queue badge announced,
  finished summary announcements.
- Info.plist NSPhotoLibraryUsageDescription wording.
- Attribute correctness: nothing that would be an @unchecked Sendable
  hiding a real race.

For each finding use the uniform template. Rank most-severe first. Cap at 20.

Write to: docs/reviews/2026-07-13/best-practices.md
Header:
# Swift / Apple Best Practices
**Reviewer:** best-practices-lens  **Date:** 2026-07-13  **Verify status:** pending

Return the file path when done.
```

- [ ] **Step 2: Verify**

Run:
```bash
test -f docs/reviews/2026-07-13/best-practices.md && grep -c '^### F' docs/reviews/2026-07-13/best-practices.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 7: Lens 6 — `cleanup.md`

**Files:**
- Create: `docs/reviews/2026-07-13/cleanup.md`

**Interfaces:**
- Consumes: `.file-map.md`.
- Produces: findings file in uniform format.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are reviewing the SwipeSort codebase for NAMING, DEAD CODE, AND
REDUNDANCY ONLY. Your output is one Markdown file — no code changes.

Read first: the spec at docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md
and docs/reviews/2026-07-13/.file-map.md.

Look for:
- Dead code (unused functions, unused @State fields, unread properties,
  unused params, unreachable branches).
- Inconsistent naming:
  - `swipeKeep` aliases `swipeFavorite` in SwipeSessionModel — which stays?
  - `totalPendingCount` vs `pendingDeletions.count` — synonyms.
  - `deleteCount` on DecisionQueue is unused by callers?
  - Any protocol method whose real impl differs semantically from the mock.
- Duplication:
  - RecentsView and AlbumGridView share ThumbnailCell, grid gesture, and
    selection state. Note what's duplicated exactly.
  - AppSettings display-name extensions in SettingsView vs default rawValue.
- Comment quality:
  - Comments that restate the code without adding a Why.
  - Stale comments referring to v0.1 skeleton behavior after v0.4+ landed.
  - Comments claiming invariants the code doesn't enforce.
- Redundancy across the protocol surface: startCachingThumbnails and
  stopCachingThumbnails vs stopCachingAllThumbnails — are all three needed?

For each finding use the uniform template. Rank most-severe first. Cap at 25
because this lens catches many small items.

Write to: docs/reviews/2026-07-13/cleanup.md
Header:
# Naming, Dead Code, Redundancy
**Reviewer:** cleanup-lens  **Date:** 2026-07-13  **Verify status:** pending

Return the file path when done.
```

- [ ] **Step 2: Verify**

Run:
```bash
test -f docs/reviews/2026-07-13/cleanup.md && grep -c '^### F' docs/reviews/2026-07-13/cleanup.md
```

Expected: file exists; grep count ≥ 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

**Parallelization note:** Tasks 2–7 have no dependencies on each other. When executing via subagent-driven-development, dispatch all six in a single message to run concurrently. Each finishes in isolation and writes to its own file.

---

## Task 8: Adversarial verify pass on high/critical findings

**Files:**
- Modify (in place): each of the six lens files — updates `**Verified:**` field per finding, may drop or reclassify.
- Modify: each lens file's header `Verify status: pending` → `pass`.

**Interfaces:**
- Consumes: all six lens files.
- Produces: same six files with each high/critical finding marked `Verified: yes (adversarial subagent confirmed)`, `plausible`, or removed.

- [ ] **Step 1: Extract high/critical findings across all six lenses**

Run:
```bash
grep -HnE '^### F.*\[SEVERITY: (critical|high)\]' docs/reviews/2026-07-13/*.md
```

Expected: a list of `<lens-file>:<line>:### F<N> — <title> [SEVERITY: high|critical]` entries. Count them — this is the verify batch size.

- [ ] **Step 2: For each high/critical finding, dispatch one `general-purpose` verify subagent in parallel**

Prompt template (substitute `<FINDING-BLOCK>`, `<FILE>`, `<LINE>`):

```
You are an adversarial verifier. Your job is to REFUTE the following
finding by reading the actual code and checking whether the described
failure scenario is real. Default to refuted=true if uncertain.

FINDING:
<FINDING-BLOCK — copy the whole ### F<N> block verbatim>

Read the referenced file and the surrounding code (±100 lines around the
cited line; more if the fix involves cross-file interactions). Then:

1. State whether the failure scenario reproduces: yes / no / partial.
2. If yes: cite the exact lines that create the failure.
3. If no: state the guard/branch/invariant that prevents it.
4. If partial: describe what's real vs what's overclaimed.

Return exactly one JSON object:
{
  "finding_id": "F<N>",
  "lens_file": "<FILE relative to repo root>",
  "verdict": "confirmed" | "plausible" | "refuted",
  "evidence": "<one paragraph>",
  "revised_severity": "critical" | "high" | "medium" | "low" | "drop"
}

Do not modify any files.
```

- [ ] **Step 3: Apply verify results to each lens file**

For every returned verdict:
- `confirmed` → set the finding's `**Verified:** yes (adversarial subagent confirmed)` and keep severity.
- `plausible` → set `**Verified:** plausible — see evidence` and paste the one-paragraph evidence under the finding.
- `refuted` → remove the finding entirely and add a one-line entry in a new `## Refuted (removed by verify pass)` section at the bottom of that lens file with the F-number, title, and reason.
- `revised_severity` different from original → update the `[SEVERITY: X]` tag; if new severity is `low` or `medium`, move the finding down so ranking stays severity-first.

After processing every lens file, update its header from `Verify status: pending` to `Verify status: pass`.

- [ ] **Step 4: Sanity-check**

Run:
```bash
grep -HE '^\*\*Verified:\*\* pending' docs/reviews/2026-07-13/*.md
```

Expected: no output (every finding now has a non-pending Verified value).

Run:
```bash
grep -HE '^\*\*Reviewer:\*\* .* \*\*Date:\*\* 2026-07-13 +\*\*Verify status:\*\* pass' docs/reviews/2026-07-13/*.md
```

Expected: six matches, one per lens file.

- [ ] **Step 5: Checkpoint (no commit)**

---

## Task 9: Synthesis README + triage table

**Files:**
- Create: `docs/reviews/2026-07-13/README.md`

**Interfaces:**
- Consumes: all six verified lens files.
- Produces: entry-point synthesis file with top-10 findings and a triage table awaiting user input.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
Read every file under docs/reviews/2026-07-13/ (correctness.md,
architecture.md, performance.md, testing.md, best-practices.md, cleanup.md).

Write docs/reviews/2026-07-13/README.md with exactly this structure:

# SwipeSort Review — 2026-07-13

## Overview
<one paragraph: what was reviewed, how, and the shape of results across lenses>

## Lens summary

| Lens | Findings | Critical | High | Medium | Low |
|------|----------|----------|------|--------|-----|
| Correctness | N | N | N | N | N |
| Architecture | N | N | N | N | N |
| Performance | N | N | N | N | N |
| Testing | N | N | N | N | N |
| Best Practices | N | N | N | N | N |
| Cleanup | N | N | N | N | N |

## Top 10 findings across all lenses

Rank by severity, break ties by lens order above. Merge near-duplicates
(same file:line hit by two lenses) into a single entry that links both.

For each entry:

### 1. <title> — <SEVERITY>
- **From:** [<lens>.md#f<n>](./<lens>.md#f<n>-<slug>)
- **File:** <path>:<line>
- **One-liner:** <what>
- **Impact:** <why it matters>

## Triage table (user fills)

| # | Finding | Accept? | Notes |
|---|---------|---------|-------|
| 1 | <title> | [ ] accept  [ ] defer  [ ] won't-fix | |
| 2 | ... | | |
| 3 | ... | | |
| 4 | ... | | |
| 5 | ... | | |
| 6 | ... | | |
| 7 | ... | | |
| 8 | ... | | |
| 9 | ... | | |
| 10| ... | | |

## How to proceed
1. Read this README top to bottom.
2. Skim each lens file, focusing on findings above `medium`.
3. Fill the triage table.
4. Reply "triaged" to trigger the doc-comment pass (Task 10 of the plan).
```

- [ ] **Step 2: Verify README exists and includes all required sections**

Run:
```bash
test -f docs/reviews/2026-07-13/README.md \
  && grep -c '^## Top 10 findings across all lenses' docs/reviews/2026-07-13/README.md \
  && grep -c '^## Triage table' docs/reviews/2026-07-13/README.md
```

Expected: file exists; each grep returns 1.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 10: User triage gate — HALT

**Files:** none.

**Interfaces:**
- Consumes: `README.md` + six lens files.
- Produces: user-completed triage table in `README.md`.

- [ ] **Step 1: Present the review to the user**

Message the user exactly:

> "Review complete. Findings live under `docs/reviews/2026-07-13/`. Start with `README.md` — it has a lens summary, the top-10 across all lenses, and a triage table for you to fill in. When you're done, reply **triaged** and I'll run the doc-comment pass."

- [ ] **Step 2: WAIT**

Do not proceed to Task 11 until the user replies `triaged` (or an equivalent go-ahead) with the README's triage column filled.

- [ ] **Step 3: Read the completed triage table**

Read `docs/reviews/2026-07-13/README.md` and note which top-10 items are marked `accept`. This informs the downstream fix plans (Task 13), not the doc pass.

---

## Task 11: Doc-comment pass

**Files:**
- Modify: every `.swift` file under `SwipeSort/` that has a public or internal declaration missing a `///` doc comment, or a comment that is stale/wrong/redundant.
- No test files modified.

**Interfaces:**
- Consumes: nothing from prior tasks except the user's approval.
- Produces: a set of file edits containing only comment/whitespace changes.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are executing the DOC-COMMENT PASS for SwipeSort. You may modify only
comments and whitespace in .swift files under SwipeSort/. NO code semantics
change. NO signature changes. NO test file changes.

Quality bar: "Public API + tricky bits only."
1. Every public or internal type, protocol, method, and property that is
   part of the module's surface gets a `///` doc comment.
2. `///` comments should explain WHAT the declaration does and, when
   non-obvious, WHY (invariants, threading rules, PhotoKit gotchas).
3. Inline `//` comments are kept only where the WHY is non-obvious:
   a hidden constraint, a subtle invariant, a workaround for a specific
   bug, behavior that would surprise a reader.
4. DELETE comments that:
   - Restate what the code already says.
   - Reference removed code or old versions (v0.1 skeleton notes that
     no longer apply now that v0.4+ landed).
   - Contradict the current implementation.
5. For every comment that survives or is added, if it names a THREADING,
   ORDERING, or PHOTOKIT INVARIANT, structure the body as one line
   followed by a "Why: ..." line so future readers can judge edge cases.

HARD RULES (must not violate — the environment has no Xcode to catch
compile errors):
- Do not change any signature, parameter name, generic constraint, or
  attribute list (@available, @objc, @MainActor, @Observable, etc.).
- Do not change any macro invocation arguments.
- Do not reorder declarations (breaks source order that DocC and
  synthesised interfaces rely on).
- Do not touch strings, numeric literals, or types.
- Do not add /// to `private` declarations unless one already exists
  and needs correction.

Files to walk (in this order — commit-style batches):
Batch A — Core types
  SwipeSort/Core/PhotoLibraryProviding.swift
  SwipeSort/Core/AssetIdentifier is defined in PhotoLibraryProviding.swift
  SwipeSort/Core/SwipeDecision.swift
  SwipeSort/Core/DryRunMode.swift
  SwipeSort/Core/AppSettings.swift
  SwipeSort/Core/PixelSize.swift
  SwipeSort/Core/UserAlbum.swift
  SwipeSort/Core/SwipeFilter.swift
  SwipeSort/Core/PhotoLibraryChangePublisher.swift

Batch B — Core implementations
  SwipeSort/Core/PhotoKitLibrary.swift
  SwipeSort/Core/MockPhotoLibrary.swift
  SwipeSort/Core/VideoPlayerPool.swift
  SwipeSort/Core/WindowedThumbnailCache.swift

Batch C — Swipe feature
  SwipeSort/Features/Swipe/SwipeSessionModel.swift
  SwipeSort/Features/Swipe/SwipeStackView.swift
  SwipeSort/Features/Swipe/SwipeCardView.swift
  SwipeSort/Features/Swipe/VideoCardView.swift
  SwipeSort/Features/Swipe/LivePhotoCardView.swift
  SwipeSort/Features/Swipe/FullResViewer.swift
  SwipeSort/Features/Swipe/ReviewCommitView.swift

Batch D — Landing feature
  SwipeSort/Features/MainTabView.swift
  SwipeSort/Features/Landing/RecentsView.swift
  SwipeSort/Features/Landing/AlbumsView.swift
  SwipeSort/Features/Landing/AlbumPickerSheet.swift
  SwipeSort/Features/Landing/AlbumFilterSheet.swift
  SwipeSort/Features/Landing/FilterSheet.swift
  SwipeSort/Features/Landing/BulkDeleteView.swift

Batch E — Settings + app root
  SwipeSort/Features/Settings/SettingsView.swift
  SwipeSort/Features/Settings/AboutView.swift
  SwipeSort/SwipeSortApp.swift

For each file: apply the rules above and save. Do NOT summarize per-file
changes in prose — the diff is the audit trail.

When all batches are done, return the list of modified files.
```

- [ ] **Step 2: Verify only comments/whitespace changed**

Run (bash — requires `git` if the user initialised a repo; otherwise skip this specific check and rely on Task 12's verifier):

```bash
if [ -d /home/harshal.patil/Documents/SwipeSort/.git ]; then
  git -C /home/harshal.patil/Documents/SwipeSort diff --stat SwipeSort/
  git -C /home/harshal.patil/Documents/SwipeSort diff -w SwipeSort/ | head -20
fi
```

Expected (if git present): `--stat` shows the modified files; `-w` (whitespace-ignoring) diff should show ONLY comment changes — no code lines added or removed after whitespace normalization.

If not a git repo, defer verification entirely to Task 12.

- [ ] **Step 3: Checkpoint (no commit)**

---

## Task 12: Post-doc verify

**Files:** none created; may append a note to `docs/reviews/2026-07-13/README.md`.

**Interfaces:**
- Consumes: the modified Swift files from Task 11 and (if available) `git diff` output.
- Produces: a one-line verdict per batch (A–E) appended to `README.md` under a new `## Doc-pass verify` section.

- [ ] **Step 1: Dispatch a `general-purpose` subagent with this exact prompt**

Prompt:

```
You are the POST-DOC VERIFIER. Confirm that the doc-comment pass in Task 11
did not change any code semantics.

For each of the five batches (A–E) listed in Task 11's file list, read
every file in the batch and answer:

1. Are there any signature changes (parameter name, type, return type,
   generic constraint, throws, async, attributes)? — must be NO.
2. Are there any changes to string literals, numeric literals, or
   references to types/functions? — must be NO.
3. Are any declarations reordered? — must be NO.
4. Are there any `@available`, `@objc`, `@MainActor`, `@Observable`,
   `@Environment`, `@State`, `@Binding`, `@Bindable`, `@ObservationIgnored`
   or other attribute changes? — must be NO.
5. Do any surviving `//` comments contradict the surrounding code? — must be NO.

If a `git diff` is available (repo initialised), rely on it for
authoritative before/after. Otherwise reason from source alone by
cross-checking each `///` block against the declaration it precedes.

Append a `## Doc-pass verify` section to
docs/reviews/2026-07-13/README.md with one row per batch:

| Batch | Files | Verdict | Notes |
|-------|-------|---------|-------|
| A — Core types           | N | pass / FAIL | <one line> |
| B — Core implementations | N | pass / FAIL | <one line> |
| C — Swipe feature        | N | pass / FAIL | <one line> |
| D — Landing feature      | N | pass / FAIL | <one line> |
| E — Settings + app root  | N | pass / FAIL | <one line> |

If any batch is FAIL, list the specific offending file:line in the Notes
column. Do not modify the Swift files — flag the failure so the human can
decide whether to revert or re-run Task 11.
```

- [ ] **Step 2: Verify the README now has the verify section**

Run:
```bash
grep -c '^## Doc-pass verify' docs/reviews/2026-07-13/README.md
```

Expected: 1.

Run:
```bash
grep -E '\| .* \| .* \| FAIL \|' docs/reviews/2026-07-13/README.md
```

Expected: no output on a clean run. If any FAIL rows show up, STOP and surface them to the user before proceeding.

- [ ] **Step 3: Present final deliverables to the user**

Message the user:

> "Doc-comment pass applied and verified. Deliverables:
> - `docs/reviews/2026-07-13/` (README + 6 lens files + triage + verify).
> - Modified Swift files under `SwipeSort/` — comments only.
>
> Nothing has been committed. Review the diff at your leisure, then let me know if you want me to:
> (a) turn the accepted findings into downstream implementation plans (one per cluster), or
> (b) revise any part of this."

---

## Task 13: Downstream fix plans (deferred — outside this plan)

This is a placeholder marker. Do NOT execute here. The doc pass is the terminal deliverable of this cycle.

When the user is ready, invoke `superpowers:writing-plans` once per accepted-findings cluster (e.g., one plan for "split SwipeStackView", one for "Sendable + Swift 6 gaps", one for "missing PhotoKit iCloud tests", etc.). Each cluster's plan lives at `docs/superpowers/plans/YYYY-MM-DD-<cluster>.md` and follows the same task-by-task discipline.

---

## Self-Review

**Spec coverage:**
- §1 Goal & Scope → Global Constraints + Task 11's HARD RULES.
- §2 six lenses → Tasks 2–7, one per lens.
- §3 execution shape (fan-out, verify, synthesis, triage, doc pass, post-doc verify) → Tasks 2–7 (fan-out), 8 (verify), 9 (synthesis), 10 (triage gate), 11 (doc pass), 12 (post-doc verify).
- §4 deliverables (six lens files + README + doc diff + fix plans) → Tasks 2–9, 11, and 13 marker.
- §5 success criteria (all six files exist, README top-10 signed off, doc pass diff applied, no semantics moved, no attribute changes) → Tasks 2–7 verify greps, Task 9 grep, Task 10 gate, Task 11 hard rules, Task 12 verify.
- §6 non-goals (no features, no rename, no new tests, no commits) → Global Constraints + Task 11 hard rules + Task 10/12 explicit non-commit checkpoints.
- §7 risks (false positives, disagreement, silent compile break, scope creep) → Task 8 adversarial verify, Task 9 dedup by file:line, Task 12 post-doc verify, Task 13 explicit deferral marker.

**Placeholder scan:** No `TBD` / `TODO` / `fill in`. All step commands are concrete. All subagent prompts are complete.

**Type consistency:** Lens filenames are used identically across Tasks 2–9 and 12. `Verify status` string matches across templates. Batch names (A–E) match between Tasks 11 and 12. Every referenced source-file path exists (confirmed against `.file-map.md` in Task 1).

Plan is ready to execute.
