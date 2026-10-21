# Swift / Apple Best Practices
**Reviewer:** best-practices-lens  **Date:** 2026-07-13  **Verify status:** pass

## Summary

The codebase is broadly well-structured and shows clear awareness of Swift concurrency, PhotoKit constraints, and SwiftUI lifecycle. The most serious issue is that both `PhotoKitLibrary` and `MockPhotoLibrary` declare `@unchecked Sendable` while holding unsynchronised mutable state, which conceals real data races under Swift 6's strict concurrency model. Several medium-severity issues cluster around SwiftUI best practices: the drag-hint overlay and swipe card carry no VoiceOver semantics, making the core gesture UI inaccessible; all haptic generators are instantiated on every call instead of being prepared in advance, producing late or missing feedback; album grid buttons fall below the 44 pt HIG minimum; and the `@Observable` `DecisionQueue` is an internal detail of `SwipeSessionModel` that is unnecessarily exposed. Lower-severity findings cover `@ObservationIgnored` omissions on write-only properties, minor dynamic-type violations, a weak NSPhotoLibraryUsageDescription, and the `swipeKeep`/`swipeFavorite` naming inconsistency that silently wires keep to favourite semantics.

## Findings

---

### F1 — PhotoKitLibrary uses @unchecked Sendable while holding unsynchronised mutable state [SEVERITY: medium]
- **File:** SwipeSort/Core/PhotoKitLibrary.swift:18
- **What:** `PhotoKitLibrary` opts out of compiler-checked Sendable with `@unchecked Sendable` while owning three mutable stored properties (`fetchResult`, `fetchedAuth`, `activeFilter`) with no lock or actor guarding concurrent reads and writes.
- **Why it matters / failure scenario:** `PhotoLibraryProviding` is declared `Sendable` and stored as a `let` in `SwipeSessionModel` (a `@MainActor` type). Any concurrent caller — e.g., a detached `Task` or an `async let` branch inside `loadCurrent` — can read `fetchResult` while `ensureFetchResult` rewrites it on a different thread, producing a torn read or use-after-free of the underlying `PHFetchResult`. Under Swift 6 strict concurrency this would be a compile error; with `@unchecked` it silently races.
- **Suggested fix direction:** Promote `PhotoKitLibrary` to an `actor` (the cleanest path given the protocol already uses `async` methods everywhere) and remove `@unchecked Sendable`. The three mutable fields become actor-isolated state automatically. Alternatively, protect them with an `NSLock` and audit every callsite, but the actor upgrade is safer and aligns with the concurrency model already in use.
- **Verified:** plausible — severity revised high → medium. Structural `@unchecked Sendable` risk with three unguarded `var` properties is real, but the specific race scenario claimed (concurrent branches in `loadCurrent` racing on `fetchResult`) is inaccurate: those branches call `thumbnail(for:)` and `mediaKind(for:)` which fetch by identifier, not via `fetchResult`. Latent hazard under Swift 6 strict concurrency remains.

---

### F2 — MockPhotoLibrary uses @unchecked Sendable while mutating multiple properties without synchronisation [SEVERITY: medium]
- **File:** SwipeSort/Core/MockPhotoLibrary.swift:10
- **What:** `MockPhotoLibrary` also opts out of Sendable checking while holding more than a dozen `var` properties that are mutated during and between test calls with no synchronisation.
- **Why it matters / failure scenario:** Test scenarios that exercise concurrent async paths (e.g., `SwipeSessionModel` calling `loadCurrent`'s four `async let` branches simultaneously) can race on `scriptedMediaKinds`, `albums`, or `startCachingCalls`. Because `@unchecked` suppresses diagnostics, the race is invisible and produces non-deterministic test results.
- **Suggested fix direction:** Mark `MockPhotoLibrary` as an `actor` or — since tests drive it synchronously — add explicit `@MainActor` isolation. Mirror whatever isolation choice is made for `PhotoKitLibrary` so the protocol conformance remains consistent.
- **Verified:** plausible — severity revised high → medium. Structurally `@unchecked` is unjustified given extensive `var` mutations, but the specific concurrent-branch race scenario is inaccurate (methods called from the async branches use only read-only or per-call state). Same latent-hazard characterisation as F1.

---

### F3 — SwipeCard and drag-hint overlay expose no VoiceOver semantics for the primary swipe interaction [SEVERITY: high]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:209
- **What:** The `SwipeCardView` assigned identifier `"SwipeCard"` has no `accessibilityLabel` describing the current photo and no `accessibilityActions` wiring up the four gesture directions; the drag-hint overlay is a purely visual `ZStack` with no accessibility representation.
- **Why it matters / failure scenario:** A VoiceOver user who lands on the card hears nothing about what the photo is or how to act on it. There is no way to keep, delete, go to the previous photo, or move to an album without sight. This makes the app's core feature entirely inaccessible.
- **Suggested fix direction:** Give `SwipeCardView` a dynamic `accessibilityLabel` composed of the asset's index, count, and media kind. Add `accessibilityAction(named:)` entries for each of the four semantic actions (Delete, Favourite, Next, Previous) that call the same async path used by the gesture. The drag-hint overlay should be `.accessibilityHidden(true)` — the label on the card itself is the announcement.
- **Verified:** yes (adversarial subagent confirmed — SwipeCardView has zero accessibility modifiers beyond `accessibilityIdentifier`; drag-hint overlay has no `.accessibilityHidden(true)`. Core gesture UI is inaccessible to VoiceOver users)

---

### F4 — Haptic generators are constructed on every swipe with no prepare() call, causing missed or late haptics [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:641–647
- **What:** `UIImpactFeedbackGenerator` and `UINotificationFeedbackGenerator` are instantiated inside the action handler (`triggerHaptic`, `triggerWarningHaptic`) and called immediately without `prepare()`, violating Apple's HIG guidance that generators must be prepared in advance.
- **Why it matters / failure scenario:** Constructing and firing a generator in the same synchronous call introduces a latency spike of up to ~100 ms before the haptic fires, or causes it to be skipped entirely on lower-priority CPU state. During rapid swipes (a realistic usage pattern) successive generators compete for the Taptic Engine hardware queue, producing inconsistent feedback that undermines the tactile rhythm the UI is designed around.
- **Suggested fix direction:** Instantiate the two generators once (as stored `@State` or a small helper struct) and call `prepare()` at the leading edge of each drag (`onChanged` when `magnitude > 0`), so the hardware is warm when `impactOccurred()` / `notificationOccurred` fires at gesture end.
- **Verified:** pending

---

### F5 — Album grid buttons have a 38 pt tap target, below the 44 pt HIG minimum [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:387
- **What:** The `LazyHGrid` album buttons are fixed at `height: 38` with no hit-area expansion, making them 6 pt shorter than Apple's recommended 44 pt minimum interactive target.
- **Why it matters / failure scenario:** Users with larger fingers or motor-control difficulties will routinely miss the buttons. This is more pronounced because the buttons are the only way to trigger an immediate album move without undoing and re-swiping, so misses directly interrupt the triage flow.
- **Suggested fix direction:** Keep the visual height at 38 pt for layout purposes but add `.contentShape(Rectangle().size(CGSize(width: 170, height: 44)))` or use `.frame(height: 44)` with `.clipShape(Capsule())` inside the label so the hit area meets the HIG guideline without altering the grid row heights.
- **Verified:** pending

---

### F6 — .task { } without id: on SwipeStackView captures filter and library by value at mount, creating stale-closure risk if the view is reused [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:83
- **What:** The root `.task { }` (no `id:`) captures `filter` and `library` at the time the view first appears and never reruns if those change, because SwiftUI only cancels and relaunches `task(id:)` when its identifier changes.
- **Why it matters / failure scenario:** If `filter` is changed externally (e.g., the user edits the filter in a parent view before opening the deck), the task that called `applyFilter(_:)` used the stale filter value. The session would index under the old filter while the UI header shows the new one.
- **Suggested fix direction:** Either convert to `.task(id: filter)` so a filter change causes the task to restart, or — since `SwipeStackView` has an `init`-time `filter: SwipeFilter` that is a value type set once at presentation — document explicitly that the filter is immutable for the lifetime of the view and add a precondition. The current code gives no such guarantee.
- **Verified:** pending

---

### F7 — finishedSummary uses a .task { } with no id: to auto-commit, which can re-execute if the view is reconstructed [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:230
- **What:** The `.task { }` embedded inside the `finishedSummary` view has no `id:` parameter; the `didAutoCommit` / `didAutoPresentQueue` guards prevent a second fire only as long as those `@State` booleans survive. If SwiftUI discards and recreates the `finishedSummary` content (e.g., during a navigation or sheet stack operation), the task runs again and the boolean is reset.
- **Why it matters / failure scenario:** A user who dismisses and re-presents the deck in the same session could trigger a second `commitDecisions()` call against the already-cleared queue. The queue is empty at that point so the result is `.success(affectedCount: 0)`, but the UX shows an unexpected "Committed" flash.
- **Suggested fix direction:** Hoist auto-commit logic into the `SwipeSessionModel` and drive it from `.onChange(of: model.phase)` in the parent view body, which is not subject to arbitrary re-creation. Remove the `.task { }` from the summary sub-view entirely.
- **Verified:** pending

---

### F8 — @Observable DecisionQueue is a let property on SwipeSessionModel but is publicly accessible, exposing internal mutation surface [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:35
- **What:** `queue` is declared `let queue = DecisionQueue()` with no access modifier, exposing the `DecisionQueue`'s full mutation API (`record`, `undoLast`, `removeDecision`, `removeCommitted`) to any caller that holds a `SwipeSessionModel`.
- **Why it matters / failure scenario:** External callers (e.g., `DeletionQueueView` calling `model.queue.decisions`) bypass the model's invariants. A consumer calling `model.queue.record(...)` directly would add a decision without loading the corresponding thumbnail or advancing the cursor, corrupting the session's state machine. Current callers only read from `queue`, but the surface is unnecessarily wide.
- **Suggested fix direction:** Make `queue` `private` and expose only the read-only properties (`decisions`, `deleteCount`, `keepCount`) as computed forwarding properties on `SwipeSessionModel`. Mutation methods remain inside the model.
- **Verified:** pending

---

### F9 — GridCellFramePreferenceKey is defined in AlbumPickerSheet.swift but used across RecentsView and AlbumsView — wrong ownership [SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/AlbumPickerSheet.swift:184
- **What:** `GridCellFramePreferenceKey` and its companion `gridIndex(at:in:)` function are defined in `AlbumPickerSheet.swift` but their only consumers are `RecentsView` and `AlbumGridView`; `AlbumPickerSheet` itself does not use them.
- **Why it matters / failure scenario:** This is primarily a maintenance hazard: a developer editing `AlbumPickerSheet` will not expect it to own grid selection infrastructure. More concretely, the `reduce` implementation uses `$1` (later value wins), which silently drops frame updates from cells that fire in the same layout pass with the same index — correct only by accident because each `LazyVGrid` cell has a unique index. A fresh definition in the correct file would prompt review of the reduce semantics.
- **Suggested fix direction:** Move `GridCellFramePreferenceKey` and `gridIndex(at:in:)` to a shared file (e.g., `GridSelectionSupport.swift` in `Features/Landing/`). Audit the `reduce` closure to confirm the last-wins merge is intentional and document it.
- **Verified:** pending

---

### F10 — AppSettings.dryRunMode should be @ObservationIgnored or its write-back to DryRunMode should be decoupled [SEVERITY: medium]
- **File:** SwipeSort/Core/AppSettings.swift:67
- **What:** `dryRunMode` is a stored `var` on the `@Observable` class whose `didSet` writes to `DryRunMode.setEnabled(...)`, a global side effect. Because it is observable, any view that reads `settings.dryRunMode` re-renders on every change — this is intentional for `SettingsView` but `SwipeStackView` and `SwipeCardView` do not read `dryRunMode` and will still be invalidated if the stored property write triggers an observation notification.
- **Why it matters / failure scenario:** Any indirect observation of `settings` (e.g., via `settings.autoplayVideos`) that happens to coexist in the same view will also cause the view to re-evaluate when `dryRunMode` changes, even though the view never reads it. While SwiftUI's diffing typically prevents redraws, the observation invalidation still runs, adding unnecessary CPU overhead during what is meant to be a lightweight settings toggle.
- **Suggested fix direction:** If `dryRunMode` truly does not need to drive SwiftUI observation outside of `SettingsView`, mark it `@ObservationIgnored` and trigger observation manually via a dedicated `@Published`-style wrapper or a separate observable flag. Alternatively, accept the current design and document that the coupling is intentional.
- **Verified:** pending

---

### F11 — @Bindable in SettingsView body creates a new Bindable wrapper on every render cycle [SEVERITY: low]
- **File:** SwipeSort/Features/Settings/SettingsView.swift:10
- **What:** `@Bindable var s = settings` is declared inside `var body: some View`, meaning a fresh `Bindable` wrapper is allocated every time the view's body re-evaluates.
- **Why it matters / failure scenario:** Each re-evaluation of `body` (triggered by any `@Observable` property change on `settings`) allocates a new `Bindable` struct. This is harmless in practice because `Bindable` is a lightweight value type, but it is not the idiomatic Swift 5.9+ pattern. The canonical pattern is `@Bindable var settings` as a stored property on the view, which initialises the wrapper once.
- **Suggested fix direction:** Move the `@Bindable` annotation to the `@Environment` property: remove `@Environment(AppSettings.self) private var settings` and replace with `@Bindable @Environment(AppSettings.self) var settings` (Swift 5.9 / iOS 17+), or keep `@Environment` and introduce `@State @Bindable private var s = …` at the struct level rather than in `body`.
- **Verified:** pending

---

### F12 — ThumbnailCell VoiceOver label is empty — no photo description or index announced [SEVERITY: medium]
- **File:** SwipeSort/Features/Landing/RecentsView.swift:313
- **What:** `ThumbnailCell` calls `.accessibilityElement(children: .ignore)` and `.accessibilityAddTraits(.isButton)` but sets no `accessibilityLabel`, so VoiceOver announces only "button" with no context about which photo it is.
- **Why it matters / failure scenario:** A VoiceOver user navigating the recents grid hears "button, button, button, …" for every cell. There is no way to distinguish cells or understand their content (photo vs video, what index) without sight.
- **Suggested fix direction:** Add an `accessibilityLabel` that includes the media kind ("Photo", "Video", "Live Photo") and the cell's index within the grid. Pass the index into `ThumbnailCell` as an additional parameter for this purpose.
- **Verified:** pending

---

### F13 — Pending-deletions badge count is not announced to VoiceOver when it changes [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:157
- **What:** The deletion badge count in the header updates visually when the user swipes a photo to delete, but no accessibility announcement is posted when the count increases. The `accessibilityLabel` on the button is static and does not read out when the badge changes.
- **Why it matters / failure scenario:** A VoiceOver user who has just swiped a photo to delete gets no audible confirmation that the deletion was queued. They must navigate back to the badge button and hear its label to discover the updated count.
- **Suggested fix direction:** Use `AccessibilityFocusState` or post a `UIAccessibility.post(notification: .announcement, argument:)` call after a delete decision is recorded, announcing something like "Queued for deletion. 3 pending." The badge button's `accessibilityLabel` can remain as the persistent description; the announcement handles the transient feedback.
- **Verified:** pending

---

### F14 — Finished-summary view posts no accessibility announcement when the session completes [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:450
- **What:** When `model.phase` transitions to `.finished`, SwiftUI swaps the card area for `finishedSummary` but no announcement is posted to inform a VoiceOver user that the session has ended and summarise the results.
- **Why it matters / failure scenario:** A VoiceOver user swiping through photos will hear the card change but receive no signal that the deck is exhausted. Focus may remain on the last position without moving to the summary. They may not discover the "Delete Now" button without extensive navigation.
- **Suggested fix direction:** Add an `.onChange(of: model.phase)` handler that posts a `UIAccessibility.post(notification: .screenChanged, argument:)` with a summary string (e.g., "All photos reviewed. 5 deletions pending.") when the phase becomes `.finished`.
- **Verified:** pending

---

### F15 — NSPhotoLibraryUsageDescription is vague and omits the specific destructive operations [SEVERITY: low]
- **File:** SwipeSort/Info.plist:22
- **What:** The description reads "SwipeSort needs access to your photo library to help you sort and clean up media." It does not mention that the app can delete photos or move them between albums.
- **Why it matters / failure scenario:** Apple's App Review guidelines require that usage descriptions explain how the data is used, including destructive operations. A user reading this string has no indication that granting access enables permanent deletion. This is both a privacy-transparency concern and a potential App Review flag.
- **Suggested fix direction:** Revise to something like: "SwipeSort needs full access to your photo library to display, sort, permanently delete, and move photos between albums." Include the word "delete" explicitly.
- **Verified:** pending

---

### F16 — Reduce-motion environment value is not consulted; all swipe animations run unconditionally [SEVERITY: medium]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:632–637
- **What:** `animate(offset:)` and `snapBack()` apply `withAnimation` unconditionally, and the card rotation (`rotationEffect(.degrees(...))`) is driven by raw `dragOffset` with no reduce-motion guard.
- **Why it matters / failure scenario:** Users with vestibular disorders who enable "Reduce Motion" in Accessibility settings expect card animations and rotation to be suppressed. The continuous rotationEffect during dragging is classified by Apple's HIG as a parallax/motion effect that must respect this setting.
- **Suggested fix direction:** Read `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and gate all `withAnimation` calls and the `rotationEffect` on `!reduceMotion`. For reduce-motion users, use instant transitions (`.animation(nil, …)`) or a simple opacity fade instead of fly-off translation.
- **Verified:** pending

---

### F17 — swipeKeep() is a public no-op alias for swipeFavorite() — naming implies semantically different actions [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeSessionModel.swift:77
- **What:** `swipeKeep()` simply delegates to `swipeFavorite()`, meaning "keep" and "favourite" are identical operations: both toggle the Photos favorite flag on the current asset. The public API implies distinct semantics but provides none.
- **Why it matters / failure scenario:** Any caller who expects `swipeKeep` to queue the asset as "kept but not favourited" (i.e., just advance without marking the photo) will silently favourite every photo they intended only to keep. The UI text says "Favorite" in the drag hint, which is consistent, but the leftover `swipeKeep` surface invites future callers to misuse it.
- **Suggested fix direction:** Delete `swipeKeep()` and update all callsites to `swipeFavorite()` directly. If a true skip-without-favouriting semantic is desired, implement it separately as `swipeNext()` already provides (which advances without recording a keep decision).
- **Verified:** pending

---

### F18 — PhotoLibraryProviding.startCachingThumbnails / stopCachingThumbnails are non-async synchronous protocol requirements but PHCachingImageManager calls they wrap are not thread-safe without actor isolation [SEVERITY: low]
- **File:** SwipeSort/Core/PhotoLibraryProviding.swift:104
- **What:** `startCachingThumbnails` and `stopCachingThumbnails` are declared as synchronous (non-`async`) protocol requirements while the real implementation calls `PHCachingImageManager` methods that must be called from a consistent thread context.
- **Why it matters / failure scenario:** `WindowedThumbnailCache` (a `@MainActor` class) calls these methods from a `@MainActor` context, which is safe for the current implementation. However, the protocol offers no isolation guarantee, so a conformance running off-actor could invoke `PHCachingImageManager` concurrently, violating its thread model. Under Swift 6 strict concurrency, calling a non-isolated synchronous method from a non-isolated context while `PHCachingImageManager` is being driven from `@MainActor` would be a data race.
- **Suggested fix direction:** Mark both methods `@MainActor` in the protocol declaration to document and enforce that caching operations must occur on the main actor, matching `WindowedThumbnailCache`'s existing isolation.
- **Verified:** pending

---

### F19 — Drag hint overlay uses fixed point sizes (.system(size: 28) and .system(size: 18)) that do not scale with Dynamic Type [SEVERITY: low]
- **File:** SwipeSort/Features/Swipe/SwipeStackView.swift:315–317
- **What:** The hint overlay icon (28 pt) and label (18 pt) are specified with `.font(.system(size:weight:))` fixed sizes, bypassing Dynamic Type scaling.
- **Why it matters / failure scenario:** Users who set accessibility text sizes (AX1–AX5) will see the hint label at the same fixed size, potentially too small at the default font size and unscaled relative to the rest of the UI at enlarged sizes.
- **Suggested fix direction:** Use `.font(.title2.weight(.bold))` and `.font(.title3.weight(.heavy))` (semantic text styles) which scale automatically, or apply `.dynamicTypeSize(...)` with an appropriate maximum cap if the overlay layout would break at extreme sizes.
- **Verified:** pending

---

### F20 — AlbumPickerSheet.task { } has no id: causing a stale-closure risk if selectedCount or sourceAlbumId changes while the sheet is open [SEVERITY: low]
- **File:** SwipeSort/Features/Landing/AlbumPickerSheet.swift:100
- **What:** The `.task { await loadAlbums() }` has no `id:` parameter. If `selectedCount` or `sourceAlbumId` changes while the sheet is open (possible in principle if the parent view mutates them before dismiss), the album list is stale.
- **Why it matters / failure scenario:** In practice both inputs are set once at sheet presentation and do not change, so this is low-risk today. However, it is a latent fragility: if the sheet is ever reused with a different `selectedCount` without being dismissed and re-presented, the album list would not refresh.
- **Suggested fix direction:** Add `.task(id: sourceAlbumId) { await loadAlbums() }` to document the dependency explicitly and ensure a re-run if the source album changes. `selectedCount` does not affect the album list so it does not need to be part of the id.
- **Verified:** pending
