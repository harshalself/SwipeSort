# SwipeSort — Code Review & Documentation Audit

**Date:** 2026-07-13
**Status:** design approved, pending implementation plan
**Related plans:** `docs/superpowers/plans/README.md` (version roadmap)

## 1. Goal & Scope

Produce an actionable, prioritized picture of what is wrong or improvable in the SwipeSort codebase across six lenses, then improve the documentation-comment layer against the code as it stands today. **No code semantics change in this phase — findings only.** Fixes become separate approved plans afterward.

### In scope
- All Swift source under `SwipeSort/` (`Core/`, `Features/`, app root) — ~4,200 lines / ~30 files.
- All tests under `SwipeSortTests/`.
- `Info.plist` and `Assets.xcassets` structure only where a finding touches them.
- Existing docs (`docs/RESEARCH.md`, `docs/superpowers/plans/*`) are read for context — never modified.

### Out of scope
- Applying any of the findings. Each accepted finding becomes a downstream plan.
- Xcode project settings, entitlements, build phases (no macOS access from the working environment).
- App Store or distribution polish — SwipeSort is personal-use per the locked decisions in `docs/superpowers/plans/README.md`.
- UI redesign or feature work.

## 2. Review Lenses

Each lens is one subagent producing one findings file at `docs/reviews/2026-07-13/<lens>.md`. Every finding carries: **severity**, **file:line**, **summary**, **failure scenario or evidence**, **suggested fix direction** (not code). Findings are ranked most-severe first within each file.

### 2.1 `correctness.md` — Correctness & bugs
Logic errors, race conditions, PhotoKit misuse, actor/threading correctness, unhandled auth states, edge cases in `SwipeSessionModel` (undo walks, prev-index searches, advance past end, initial-index resolution), `DecisionQueue` invariants, dry-run gating gaps, undo of `moveToAlbum` when source is `nil`, commit ordering when the user cancels the system prompt.

### 2.2 `architecture.md` — Architecture & modularity
Folder structure vs what the code actually does, feature coupling (grid views reaching into swipe types), `SwipeStackView` at 649 lines, `PhotoKitLibrary` at 497 lines, `PhotoLibraryProviding` surface size (candidate split into `ReadOnly` / `Mutating` / `Caching` sub-protocols), `AppSettings` sprawl (dry-run vs user prefs collision), whether `RecentsView`/`AlbumsView`/`AlbumGridView` should share a shared grid component.

### 2.3 `performance.md` — Performance & memory
`PHCachingImageManager` window semantics, `VideoPlayerPool` drain policy, `NSCache` sizing on `GridImageCache`, MainActor contention (async chains inside `loadCurrent`), thumbnail pixel-size choices vs cell size, iCloud fetch progress + failure handling, memory pressure with 50k-asset libraries, preloading window size, redundant `refreshFetchResult` + `applyFilter` call pairs in `RecentsView`/`AlbumsView`.

### 2.4 `testing.md` — Test coverage & edge cases
What each test file covers, gaps, mock fidelity vs real PhotoKit behavior, missing scenarios: empty library, denied auth mid-session, iCloud download failure, mid-session `PHPhotoLibraryChangeObserver` fires, orientation changes, rapid swipe spam, undo across a phase change, filter change mid-session (docs say don't — is it enforced?), UI test coverage of the 4-way gestures.

### 2.5 `best-practices.md` — Swift/Apple best practices
Swift 6 concurrency + `Sendable` correctness across the protocol and its implementations, `@Observable` vs `@ObservationIgnored` usage, `@Bindable` idioms, SwiftUI: `task(id:)` cancellation, `PreferenceKey` usage in the grid, `Environment` propagation into sheets and full-screen covers, `@MainActor` boundaries, HIG conformance for the swipe UI, accessibility (VoiceOver labels, dynamic type, reduce-motion).

### 2.6 `cleanup.md` — Naming, dead code, redundancy
Dead code, inconsistent naming (`swipeKeep` vs `swipeFavorite` — one aliases the other), duplicated grid infrastructure between `RecentsView` and `AlbumGridView`, stale/wrong comments, comment noise, unused params/state, `@State` fields never read.

## 3. Execution Shape

1. **Fan-out review (parallel).** Six `Explore` subagents launch simultaneously. Each is given: one lens with a scoped checklist, a file map of the codebase, and the findings-file template. Each returns a structured findings list. Wall-clock is the slowest single lens, not the sum.
2. **Adversarial verify pass (parallel).** For findings tagged `high` or `critical`, a second subagent independently attempts to refute each — reads the actual code path, checks whether the failure scenario is real. Confirmed findings keep severity; refuted ones drop to `plausible` or are removed. Lower-severity findings skip this pass to save tokens.
3. **Synthesis.** One agent writes `docs/reviews/2026-07-13/README.md`: the top-10 severity-ranked list across lenses, with links into each lens file. This is the first thing the user reads.
4. **Triage checkpoint (user).** User reads the README + skims lens files, marks which findings become work. Result: a triage note appended to the README (accepted / deferred / won't-fix).
5. **Docs pass (single agent).** With review findings settled, one agent walks every public type/method and adds/fixes `///` doc comments per the "public API + tricky bits only" bar. Deletes redundant comments. Produces a single diff.
6. **Post-doc verify (single agent).** Re-reads the changed files to confirm only comments/whitespace changed, no stale comments survived, no doc contradictions with source.
7. **Downstream fix plans (deferred).** Separate `writing-plans` invocations, one per cluster of accepted findings. Not part of this spec — this spec ends at the doc pass.

### Skills involved
- `superpowers:dispatching-parallel-agents` for the fan-out and adversarial verify.
- `superpowers:systematic-debugging` inside the correctness lens when a finding needs verification of a suspected bug.
- `code-review` and `simplify` skills as reference for what a good finding looks like — adapted for a whole-codebase, no-git-diff context.
- `superpowers:writing-plans` after this spec is approved, and again per accepted-findings cluster.

## 4. Deliverables

Created in this order:

1. `docs/superpowers/specs/2026-07-13-review-and-docs-audit-design.md` — this file.
2. `docs/reviews/2026-07-13/correctness.md`
3. `docs/reviews/2026-07-13/architecture.md`
4. `docs/reviews/2026-07-13/performance.md`
5. `docs/reviews/2026-07-13/testing.md`
6. `docs/reviews/2026-07-13/best-practices.md`
7. `docs/reviews/2026-07-13/cleanup.md`
8. `docs/reviews/2026-07-13/README.md` — synthesis + triage table.
9. Modified source files under `SwipeSort/` — doc comments only, no code semantics changed. One diff.
10. Implementation plan file (from `writing-plans` after this spec is approved).

### Findings file format (uniform across all six)

```markdown
# <Lens Name>

**Reviewer:** <agent-id>  **Date:** 2026-07-13  **Verify status:** pass

## Summary
<one paragraph: what this lens found overall>

## Findings

### F1 — <one-line title> [SEVERITY: critical]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:180
- **What:** <one-sentence defect statement>
- **Why it matters / failure scenario:** <concrete inputs → wrong output>
- **Suggested fix direction:** <not code — approach only>
- **Verified:** yes (adversarial subagent confirmed)

### F2 — ...
```

### Severity rubric

- **critical** — data loss, crash, actual PhotoKit misuse that could delete or move wrong assets, security.
- **high** — wrong user-visible behavior, race conditions, missing invariants that will bite under real 50k-asset use.
- **medium** — likely-fine now but fragile / hard to change, moderate perf issues, missing test coverage of a real path.
- **low** — style, naming, minor dedup, comment cleanup.

## 5. Success Criteria

- All six findings files exist, each with severity-ranked findings and no placeholder text.
- README synthesis top-10 is signed off (triage column filled).
- Doc pass diff is applied; every public type/method in `SwipeSort/` has a `///` comment; no comment restates trivial code; tricky-bit comments carry a **Why:** or invariant note.
- No source code semantics have moved during the doc pass (verified by post-doc agent — confirms only comments/whitespace changed).
- Since Xcode cannot run in this environment, the doc-pass agent must not touch anything that could break Swift compilation: no signature changes, no rewording of `@available`, `@objc`, macro args, or attribute lists.

## 6. Non-Goals

- No new features.
- No renaming of public API in this phase (a rename recommendation is a finding, not an action).
- No test additions in this phase (a "missing test X" is a finding, not a written test).
- No git commits until the user reviews the deliverables — this session leaves everything unstaged for user review.

## 7. Risks & Mitigations

- **False positives in the review.** Adversarial verify pass on `high`/`critical` findings is the primary mitigation; the severity rubric keeps low-signal noise out of the top-10.
- **Reviewer disagreement across lenses.** Same file may appear in multiple lens files with different suggested directions. Synthesis README dedupes by `file:line` and links related findings.
- **Doc pass silently breaks compilation.** Mitigated by the "no signature / attribute / macro-arg changes" rule and the post-doc verify subagent.
- **Scope creep during triage.** Triage is a marking exercise only; each accepted finding still requires its own downstream plan before any code changes.

## 8. Approval

- Section 1 (Goal & Scope) — approved 2026-07-13
- Section 2 (Review Lenses) — approved 2026-07-13
- Section 3 (Execution Shape) — approved 2026-07-13
- Section 4 (Deliverables & Success Criteria) — approved 2026-07-13
