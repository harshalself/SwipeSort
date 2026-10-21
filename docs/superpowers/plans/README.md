# SwipeSort — Version Roadmap & Architecture Log

Personal-use SwiftUI iOS app for swipe-based photo triage against the user's Photos library.

**Research basis:** [`docs/RESEARCH.md`](../../RESEARCH.md) — technical constraints and Apple PhotoKit gotchas.

---

## Version History & Roadmaps

### Phase I: Feature Development (v0.1 – v0.7)
Iterative feature cuts authored against real 50k+ library considerations.

| Version | Deliverable | Plan | Status |
|---|---|---|---|
| **v0.1** | Skeleton: PhotoKit auth, lazy fetch, single swipe card, in-memory decision queue, no deletes | [`2026-07-06-v0.1-skeleton.md`](./2026-07-06-v0.1-skeleton.md) | **Completed** |
| **v0.2** | Real deletion (batch + system prompt), review-before-commit queue, iCloud download progress | [`2026-07-06-v0.2-deletion.md`](./2026-07-06-v0.2-deletion.md) | **Completed** |
| **v0.3** | Decision queue architecture, session resume-where-you-left-off | [`2026-07-06-v0.3-persistence.md`](./2026-07-06-v0.3-persistence.md) | **Completed** |
| **v0.4** | Album sorting: move to user album via dual collection change requests, favorites toggle | [`2026-07-06-v0.4-albums.md`](./2026-07-06-v0.4-albums.md) | **Completed** |
| **v0.5** | Media polish: `PHCachingImageManager` window, video autoplay pool, Live Photo hints | [`2026-07-06-v0.5-media.md`](./2026-07-06-v0.5-media.md) | **Completed** |
| **v0.6** | Power filters: date range, media type (photos/videos/live photos), custom sorting | [`2026-07-06-v0.6-filters.md`](./2026-07-06-v0.6-filters.md) | **Completed** |
| **v0.7** | User Settings: swipe directions, haptics, autoplay threshold, theme selection | [`2026-07-06-v0.7-settings.md`](./2026-07-06-v0.7-settings.md) | **Completed** |

---

### Phase II: Comprehensive Codebase Audit & Refactor
Post-v0.7 audit (`docs/reviews/2026-07-13/`) resolved all 105 findings across 7 phases:

| Phase | Focus & Deliverables | Plan | Status |
|---|---|---|---|
| **Phase 1** | Decision lifecycle correctness (`SwipeSessionModel` state machine, album move deduplication) | [`2026-07-14-phase-1-decision-lifecycle.md`](./2026-07-14-phase-1-decision-lifecycle.md) | **Completed** |
| **Phase 2** | Swift concurrency & Sendable safety (isolated `@MainActor` boundaries on `PhotoKitLibrary`) | [`2026-07-14-phase-2-concurrency-sendable.md`](./2026-07-14-phase-2-concurrency-sendable.md) | **Completed** |
| **Phase 3** | Shared grid extraction (`Features/Components/`) and architecture cleanup | [`2026-07-15-phase-3-architecture.md`](./2026-07-15-phase-3-architecture.md) | **Completed** |
| **Phase 4** | Performance & memory (`WindowedThumbnailCache` prefetching, library change debounce) | [`2026-07-15-phase-4-performance.md`](./2026-07-15-phase-4-performance.md) | **Completed** |
| **Phase 5** | Testing scaffolding (Swift Testing suites for edge cases, mock fidelity, failure modes) | [`2026-07-15-phase-5-testing.md`](./2026-07-15-phase-5-testing.md) | **Completed** |
| **Phase 6** | Accessibility & HIG polish (VoiceOver labels, dynamic type, tap targets) | [`2026-07-16-phase-6-accessibility.md`](./2026-07-16-phase-6-accessibility.md) | **Completed** |
| **Phase 7** | Cleanup & naming (`DeletionQueueView`, dead code removal, protocol refinement) | [`2026-07-16-phase-7-cleanup.md`](./2026-07-16-phase-7-cleanup.md) | **Completed** |
| **Grid** | Index-driven grid: lazy per-cell ID resolution (`LazyIndexedCell`) replacing 500-cap | [`2026-07-16-index-driven-grid.md`](./2026-07-16-index-driven-grid.md) | **Completed** |

---

## Current Architecture Decisions

- **Distribution:** Personal use only. No App Store paywalls or onboarding friction.
- **Bundle Identifier:** `com.harshalpatil.SwipeSort`.
- **`DryRunMode`:** UserDefaults-backed, runtime-toggleable via a hidden debug menu (long-press the swipe screen navigation title). A red "REAL DELETION ARMED" banner appears whenever dry-run mode is off. Default is `true` for development safety.
- **Deletion Trigger:** Destructive deletes fire ONLY on explicit confirmation in `DeletionQueueView` (or multi-select grid deletion prompt). No auto-commit on screen dismiss.
- **Album Move Semantics:** Atomic move — removes from source album (if applicable) and adds to destination album in a single `PHPhotoLibrary.performChanges` block.
- **Session State & Persistence:** Active swipe sessions use an in-memory observable `DecisionQueue`. User settings (theme, gestures, video autoplay) are persisted in `UserDefaults` via `AppSettings`.
- **Video Autoplay:** Muted autoplay for videos up to the user-configured duration threshold (default: 30s) managed by `VideoPlayerPool`.
- **User Settings:** Configured via the Settings tab in `MainTabView` (`SettingsView`).
- **Platform & Frameworks:** iOS 17.0+, SwiftUI, PhotoKit, Swift Testing (`import Testing`). All PhotoKit interactions flow through `PhotoLibraryProviding`.
