# Phase 6 Working Set — Accessibility + HIG Findings
**Date:** 2026-07-16
**Source:** `best-practices.md` (F3–F5, F12–F16, F19) + first-hand code sweep for a11y gaps not in the original review

## Summary
- **9** original best-practices findings scoped to Phase 6 (F3, F4, F5, F12, F13, F14, F15, F16, F19).
- **All 9 LIVE** — none has been closed by Phases 1–5.
- **3 NEW findings** discovered during the code sweep (N1–N3).
- **12 total items** to address in Phase 6.

Broad pattern: only 3 `.accessibilityLabel(...)` calls exist across the entire app (Close, Pending Deletions, Undo). Every other tappable surface — the swipe card, the drag hint, the album row, the settings picker, the grid cells, the tab bar, the finished-summary buttons, the "Review Deletions" / "Delete Now" / "Go Back" buttons — has no label or is unannotated. `@Environment(\.accessibilityReduceMotion)` is not consulted anywhere. Dynamic Type is bypassed at multiple call sites via `.font(.system(size:...))`.

## Findings

---

### F3 — SwipeCard and drag-hint overlay expose no VoiceOver semantics [SEVERITY: high] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:252-267`
- **What:** The top `SwipeCardView` at line 252 carries only `.accessibilityIdentifier("SwipeCard")` — no `accessibilityLabel`, no `accessibilityValue`, no `accessibilityAction`. The `dragHintOverlay` at line 366 is a purely visual `ZStack` with no `.accessibilityHidden(true)` and no announcement.
- **Why it matters:** VoiceOver users cannot identify the current photo, its position in the deck, or perform any swipe action. The whole core UI is inaccessible.
- **Suggested fix:**
  - Add `.accessibilityLabel(...)` computed from `model.currentKind`, `model.currentIndex + 1`, `model.totalCount` — e.g. `"Photo 5 of 12"` / `"Video 5 of 12, 12 seconds"`.
  - Add `.accessibilityValue("iCloud downloading, N percent")` when `downloadProgress` is set.
  - Add `.accessibilityAction(named:)` for Delete, Favorite, Next, Previous — each calling the same model method the gesture drives.
  - Add `.accessibilityHidden(true)` to the drag-hint overlay so it does not clutter the label.
- **Source:** best-practices.md F3

---

### F4 — Haptic generators constructed on every swipe with no prepare() [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:714-726`
- **What:** `triggerHaptic` (line 714) constructs a new `UIImpactFeedbackGenerator` on every call. `triggerWarningHaptic` (line 723) does the same for `UINotificationFeedbackGenerator`. Neither calls `prepare()` in `DragGesture.onChanged`.
- **Why it matters:** Constructing and firing a generator in the same synchronous call yields up to ~100 ms latency before the haptic fires or drops it entirely under CPU pressure. During rapid triage the tactile rhythm becomes inconsistent.
- **Suggested fix:** Hoist both generators to `@State` (or a small helper struct). Call `prepare()` from `.onChanged` when `magnitude > 0` — pre-warms the Taptic hardware. Fire from `onEnded`.
- **Source:** best-practices.md F4

---

### F5 — Album grid buttons 38 pt tall — below 44 pt HIG minimum [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:456`
- **What:** `LazyHGrid` album buttons: `.frame(width: 170, height: 38)`. Row height is `GridItem(.fixed(38))` at line 429.
- **Why it matters:** Users with larger fingers or motor-control difficulties routinely miss the button, and misses interrupt the triage flow because the album row is the only way to trigger an immediate move.
- **Suggested fix:** Keep the visual `Capsule` at 38 pt for layout, but expand the hit area to 44 pt: apply `.contentShape(Rectangle())` to a `.frame(minHeight: 44)` wrapper on the `Button`, or apply `.contentShape(Capsule().size(CGSize(width: 170, height: 44)))`. Row spacing stays untouched because the capsule keeps its visual size.
- **Source:** best-practices.md F5

---

### F12 — ThumbnailCell VoiceOver label is empty [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Components/ThumbnailCell.swift:78-79`
- **What:** `.accessibilityElement(children: .ignore)` and `.accessibilityAddTraits(.isButton)` are applied, but no `accessibilityLabel`. VoiceOver reads "Button. Button. Button." across the grid.
- **Why it matters:** Users cannot distinguish grid cells or tell photo from video from live photo.
- **Suggested fix:** Thread a `label: String` (or `index: Int`) into `ThumbnailCell` from `PhotoGridView`. Compose the label from `mediaKind` and the 1-indexed position — e.g. `"Photo 5"`, `"Video 8, 12 seconds"`, `"Live Photo 12"`.
- **Source:** best-practices.md F12

---

### F13 — Pending-deletions badge count is not announced [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:217`
- **What:** The `accessibilityLabel` is a static "View pending deletions (\(count) items)" — no announcement fires when a delete swipe increments the count. `SwipeSessionModel` posts nothing to `UIAccessibility`.
- **Why it matters:** VoiceOver users get no audible confirmation that a delete decision was queued after a swipe. They must navigate back to the badge to hear the count.
- **Suggested fix:** After each `swipeDelete()` decision, post `UIAccessibility.post(notification: .announcement, argument: "Queued for deletion. N pending.")` from either the model or a small `.onChange(of: model.pendingDeletions.count)` handler in `SwipeStackView`.
- **Source:** best-practices.md F13

---

### F14 — Finished-summary posts no accessibility announcement [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:272-273, 519-621`
- **What:** When `model.phase` transitions to `.finished`, `finishedSummary` replaces the card area but no `UIAccessibility.post(notification: .screenChanged, argument:)` fires. VoiceOver focus is left on the previous card.
- **Why it matters:** VoiceOver users have no signal that the deck ended and cannot discover the summary buttons ("Delete Now", "Review Deletions", "Go Back") without exhaustive navigation.
- **Suggested fix:** Add `.onChange(of: model.phase) { _, newPhase in if newPhase == .finished { UIAccessibility.post(...) } }` with a summary string that includes favorited/moved/pending counts.
- **Source:** best-practices.md F14

---

### F15 — NSPhotoLibraryUsageDescription is vague [SEVERITY: low] [STATUS: LIVE]
- **File:** `SwipeSort/Info.plist:22`
- **What:** Current string: "SwipeSort needs access to your photo library to help you sort and clean up media." No mention of deletion or album moves.
- **Why it matters:** App Review guidance requires that usage descriptions call out destructive operations. Users have no privacy-transparency signal that granting access enables permanent deletion.
- **Suggested fix:** Change to: "SwipeSort needs full access to your photo library to display, sort, permanently delete, and move photos between your albums."
- **Source:** best-practices.md F15

---

### F16 — Reduce-motion is not consulted; card rotates unconditionally [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:262, 706-712`
- **What:** `.rotationEffect(.degrees(Double(dragOffset.width / 20)))` at line 262 runs on every drag. `animate(offset:)` (line 706) uses `withAnimation(.easeOut(duration: 0.2))` unconditionally. `snapBack()` (line 710) uses `withAnimation(.spring(...))`. `@Environment(\.accessibilityReduceMotion)` is not read anywhere.
- **Why it matters:** Vestibular-sensitive users who enable Reduce Motion get the full rotation and translation animations. HIG requires such motion effects to be suppressed under this setting.
- **Suggested fix:** Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` to `SwipeStackView`. Gate `rotationEffect` on `!reduceMotion` (compute rotation degrees as 0 when reduced). Wrap `animate(offset:)` / `snapBack()` so that under reduce-motion the offset is set instantly (either `withAnimation(nil)` or a plain assignment inside a `Transaction(animation: nil)`).
- **Source:** best-practices.md F16

---

### F19 — Drag hint overlay uses fixed .system(size:) fonts [SEVERITY: low] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:382-384`
- **What:** Icon: `.font(.system(size: 28, weight: .bold))`. Label: `.font(.system(size: 18, weight: .heavy))`. Both bypass Dynamic Type.
- **Why it matters:** Users on AX1–AX5 sizes see the hint at the same fixed point size, incongruent with the rest of the UI.
- **Suggested fix:** Replace with semantic styles: `.font(.title2.weight(.bold))` for the icon and `.font(.title3.weight(.heavy))` for the label. Cap with `.dynamicTypeSize(...DynamicTypeSize.accessibility3)` if the overlay layout breaks at extreme sizes.
- **Source:** best-practices.md F19

---

### N1 — NEW: SwipeStackView finished-summary buttons carry no accessibility labels [SEVERITY: medium] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:568-616`
- **What:** "Review Deletions (N)", "Delete Now (N)", and both "Go Back" buttons have no `.accessibilityLabel`. VoiceOver reads the visible text — which works — but there is no `.accessibilityHint` describing consequence ("Presents the deletion review list", "Immediately submits deletions to Photos"), and no `.accessibilityIdentifier` on the destructive "Delete Now" for UI-test targeting.
- **Why it matters:** VoiceOver users hit "Delete Now" and get no warning about the destructive action. Hints are the HIG-recommended way to disambiguate before a user taps.
- **Suggested fix:** Add `.accessibilityHint("Immediately deletes the N pending photos from your library.")` to "Delete Now". Add `.accessibilityIdentifier("DeleteNowButton")` + `.accessibilityIdentifier("ReviewDeletionsButton")` + `.accessibilityIdentifier("GoBackButton")` for testability.
- **Source:** code-sweep new-finding

---

### N2 — NEW: Settings gesture-mode picker labels expose Mode 1 / Mode 2 without a11y hints [SEVERITY: low] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Settings/SettingsView.swift:26-30, 74-81`
- **What:** `Picker("Gesture Mode", selection: $s.gestureMode)` uses `Text(m.displayName)` where `displayName` is "Mode 1 (Up: Delete, Down: Fav)" / "Mode 2 (Right: Delete, Left: Fav)". VoiceOver reads the full parenthesized description, which is long and disambiguates poorly. There is no `accessibilityIdentifier` on the Picker so `SettingsIntegrationTests` cannot target it deterministically (Phase 5 already had to work around this).
- **Why it matters:** Consistency with UI-test infrastructure; better VoiceOver ergonomics.
- **Suggested fix:** Add `.accessibilityIdentifier("GestureModePicker")` on the Picker. Optionally, split `displayName` into shorter labels with an `.accessibilityLabel` override reading e.g. "Vertical delete mode" / "Horizontal delete mode".
- **Source:** code-sweep new-finding

---

### N3 — NEW: Album row in albumGrid uses no accessibility label — VoiceOver reads only "Folder. Album Name. 5" [SEVERITY: low] [STATUS: LIVE]
- **File:** `SwipeSort/Features/Swipe/SwipeStackView.swift:433-459`
- **What:** The `Button` at line 433 has no `.accessibilityLabel`. VoiceOver reads the composed `HStack` — icon "folder.fill", title, count — as fragmented text with no verb. There is no hint that tapping moves the current photo.
- **Why it matters:** VoiceOver users cannot tell what tapping an album will do.
- **Suggested fix:** Add `.accessibilityLabel("Move to \(album.title)")` + `.accessibilityHint("Moves the current photo to this album and advances the deck.")` + `.accessibilityValue("\(album.assetCount) items")`.
- **Source:** code-sweep new-finding

---

## Categorised list (for planning)

### VoiceOver labels & hints (7 findings)
- **F3** — SwipeCard label + accessibilityActions
- **F12** — ThumbnailCell label with mediaKind + index
- **F13** — Announce pending-deletions increment
- **F14** — Announce phase transition to `.finished`
- **N1** — Finished-summary button hints + identifiers
- **N2** — Gesture-mode Picker identifier + shorter labels
- **N3** — Album row label + hint

### Dynamic Type (1 finding)
- **F19** — Replace `.font(.system(size:))` in drag hint with semantic styles

### Reduce Motion (1 finding)
- **F16** — Gate `rotationEffect` + `withAnimation` on `\.accessibilityReduceMotion`

### Tap-target sizing (44 pt) (1 finding)
- **F5** — Expand album grid button hit area to 44 pt

### Haptic feedback (1 finding)
- **F4** — Hoist generators to `@State` + call `prepare()`

### HIG polish / copy (1 finding)
- **F15** — Update NSPhotoLibraryUsageDescription

---

## Notes for Phase 6 planning
- **Highest-severity first:** F3 (swipe card VoiceOver) is the only `high` in the set. Everything else is medium or low. Recommend Task 1.
- **Grouping:** F13 (post announcement on decrement) + F14 (post on finish) share the same `UIAccessibility.post` idiom — bundle in one task.
- **Model-touch tasks vs view-only tasks:** F13 + F14 involve `SwipeStackView.onChange` handlers only; F12 requires threading an index/label into `ThumbnailCell`. Keep them separate to preserve task-level review clarity.
- **No production-code risk from F15** — it's a plist string swap.
