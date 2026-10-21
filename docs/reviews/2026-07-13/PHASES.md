# SwipeSort Fix Roadmap — 2026-07-13

**Source review:** [`docs/reviews/2026-07-13/`](.)
**Total findings accepted:** 105 (0 critical, 25 high, 51 medium, 29 low)
**Decision authority:** delegated to Claude for all findings; user reviews per-phase plans.

## Approach

Fix everything, phase by phase. Each phase runs the same four-step gate:

1. **Re-verify** — a fresh subagent checks every finding scoped to the phase against the *current* code. Anything already fixed by an earlier phase is dropped from the working set. Anything whose line numbers shifted is re-anchored.
2. **Plan** — the writing-plans skill produces `docs/superpowers/plans/2026-07-13-phase-N-<name>.md` from the re-verified working set.
3. **Execute** — subagent-driven-development runs the plan task-by-task with per-task review loops.
4. **Phase complete** — user acknowledges; next phase's re-verify begins.

**Why re-verify each phase:** correctness fixes cascade. Fixing `swipeUp` double-execute in Phase 1 may resolve a testing-lens finding about that same path in Phase 5. Re-verifying prevents wasted work and stale line numbers.

## Phase order

Phases 1–3 must be sequential (each depends on the previous being stable). Phases 4–7 could interleave in theory but run sequentially for review clarity.

### Phase 1 — Decision-lifecycle correctness
- **Why first:** highest user-facing impact; other lenses (performance, testing) touch the same code paths, so fixing this first prevents Phase 4/5 from being rewritten mid-plan.
- **Scope:** correctness highs concentrated in `SwipeSessionModel` and `DecisionQueue` — double-execute, early-exit, undo not-found, unconditional `.finished`, stale `.moveToAlbum` accumulation, register-before-auth, plus in-scope correctness mediums in the same files.
- **Success:** commit/queue state machine survives all failure modes named in the correctness lens; existing tests still green; new tests cover the specific failure scenarios these findings named.

### Phase 2 — Concurrency + `Sendable` safety
- **Why after Phase 1:** callers of `PhotoKitLibrary` are still shifting in Phase 1; isolating internals against a moving target wastes work.
- **Scope:** `PhotoKitLibrary` `@unchecked Sendable` + unsynchronised state; related best-practices highs and mediums about actor boundaries and MainActor hops.
- **Success:** `PhotoKitLibrary` internals safe under concurrent async callers; no `@unchecked Sendable` on the class unless justified in a code comment.

### Phase 3 — Shared grid extraction + architecture cleanup
- **Why before performance/testing:** `RecentsView` and `AlbumGridView` are duplicated verbatim. Fixing perf/testing bugs on both copies then merging later is strictly more work than merging first.
- **Scope:** extract `GridSelectionBottomBar` / `GridCellFramePreferenceKey` / `gridIndex` out of `AlbumPickerSheet.swift` into a shared components module; deduplicate `AlbumGridView` ↔ `RecentsView`; consider splitting `PhotoLibraryProviding` into narrower sub-protocols; move `dryRunMode` off `AppSettings` per the locked-hidden-debug-menu spec.
- **Success:** one grid implementation, one preference key; consumers depend on the narrowest protocol surface they need; `dryRunMode` no longer exposed in user-facing settings.

### Phase 4 — Performance & memory
- **Scope:** performance highs — `PHCachingImageManager` start/stop pairing, window sizing vs 50k-asset libraries, redundant `refreshFetchResult` + `applyFilter` call pairs, iCloud fetch failure paths, library-change debounce, and related mediums.
- **Success:** no unbounded PhotoKit cache growth; iCloud failures surface to the UI; observer notifications don't stampede the fetch.

### Phase 5 — Testing scaffolding
- **Scope:** the missing coverage the review named — commit cancellation, mid-session `PHPhotoLibraryChangeObserver` fires, auth revocation, undo across phase changes, `moveToAlbum` symmetry, MockPhotoLibrary fidelity vs real PhotoKit.
- **Success:** every high-severity failure mode from Phase 1 has a regression test.

### Phase 6 — Accessibility + HIG polish
- **Scope:** VoiceOver labels on `SwipeCardView` + drag hint overlay + pending queue badge + finished summary announcements; dynamic type; reduce-motion; 44 pt tap targets; dark-mode contrast; haptic patterns.
- **Success:** core swipe flow is usable with VoiceOver; app respects reduce-motion and dynamic type.

### Phase 7 — Cleanup, naming, dead code
- **Scope:** `swipeKeep` alias, `totalPendingCount` vs `pendingDeletions.count` synonyms, stale v0.1 comments, dead fields, remaining lows across all lenses.
- **Success:** review at end of Phase 7 shows no `high` findings anywhere; medium/low disposition is either fixed or explicitly documented as won't-fix.

## Progress tracker

| Phase | Status | Re-verify | Plan | Execute |
|-------|--------|-----------|------|---------|
| 1 — Decision-lifecycle correctness | complete | done | done | done |
| 2 — Concurrency + Sendable         | complete   | done    | done    | done    |
| 3 — Shared grid + architecture     | complete   | done    | done    | done    |
| 4 — Performance & memory           | complete   | done    | done    | done    |
| 5 — Testing scaffolding            | complete   | done    | done    | done    |
| 6 — Accessibility + HIG            | complete   | done    | done    | done    |
| 7 — Cleanup & naming               | complete   | done    | done    | done    |

Update this table as each phase's steps complete.

## Triage decision

All 105 findings are provisionally **accepted**. Rationale: user's stated goal is "fix all the things and make this app best overall" and doesn't have time for per-finding triage. Won't-fix decisions may still emerge phase-by-phase when a finding is discovered to be already resolved or is stylistic-only — those get logged in the phase's re-verify report with a one-line justification.
