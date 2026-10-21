# Phase 7 — Cleanup, Naming, Dead Code — Implementation Plan

> **For agentic workers:** Execute inline. No git or Swift compiler available in this environment. Verify each task with `grep`/`Read` against the current tree. Every task's success criterion is "the anchor no longer contains the deleted / renamed symbol, and no lingering callers exist."

**Goal:** Close every LIVE finding from `docs/reviews/2026-07-13/phase-7-working-set.md` so a final adversarial re-review surfaces no `high` findings anywhere in the codebase.

**Architecture:** Cleanup-only phase. No new features, no behavioral changes. Deletions, renames, small idiomatic rewrites. Where a change touches the public API of `SwipeSessionModel` or `DecisionQueue`, tests must be updated in the same task so the branch stays test-green (in a real Xcode env).

**Tech Stack:** Swift 5.9+, SwiftUI, PhotoKit. Same as prior phases.

## Global Constraints

- **Backward-compatible `UserDefaults` schema.** `GestureMode` `rawValue` strings (`"upDeleteDownKeep"`, `"rightDeleteLeftKeep"`) must not change — existing installs read their gesture mode by rawValue, so a rename of the raw string bricks user settings. Only the Swift case identifier changes.
- **No new tests except those explicitly listed under Task 11.** This phase is subtractive; adding coverage beyond the pins in the working-set doc is scope creep.
- **Delete, don't deprecate.** No `@available(*, deprecated)` on removed symbols — this is an in-house iOS app, not a public SDK. Clean rip.
- **Preserve the phase-1..6 fix-comment record.** Comments annotated `(W7 fix)`, `(Finding 3 fix)`, `(F4 fix)` etc. document *why* the current code shape exists and stay put. This plan only removes `v0.x`-style forward-references that were already flagged, and only where they still exist (most have been closed by earlier phases).

---

## Task 1: Delete `swipeKeep()` and update test call sites

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift:116-134`
- Modify: `SwipeSortTests/SessionResumeTests.swift:59-60`
- Modify: `SwipeSortTests/CommitDeletionsTests.swift:18,57`

**Interfaces:**
- Removes: `SwipeSessionModel.swipeKeep() async`
- Consumers: 4 test call sites migrate to `swipeFavorite()` (which records a `.keep` decision AND advances — same observable behavior for the queue-length assertions the tests make; the extra `setFavorite` side-effect is a no-op on `MockPhotoLibrary`'s in-memory state as far as those specific tests observe).

- [ ] **Step 1: Delete the method**

In `SwipeSessionModel.swift`, delete lines 116-134 (the doc-comment block and the entire `func swipeKeep() async { ... }` body):

```swift
    /// Records a `.keep` decision for the current asset and advances without any
    /// library side-effect.
    ///
    /// "Keep" means "do not delete; no change to the Photos favourite flag."
    /// To explicitly favourite an asset use `swipeFavorite()` or `toggleFavorite(_:)`.
    ///
    /// Decoupled from `swipeFavorite()` to prevent silently marking every kept
    /// asset as a Photos favourite — a destructive change the user did not request
    /// (W7 fix).
    ///
    /// Calls `removeDecision(for:)` before recording so that if the user navigated
    /// back via swipePrev and re-decided an asset, the old conflicting decision is
    /// replaced rather than duplicated (Finding 3 fix).
    func swipeKeep() async {
        guard let thumb = currentThumbnail else { return }
        queue.removeDecision(for: thumb.identifier)
        queue.record(.keep(thumb.identifier))
        await advance()
    }
```

Also strip the `swipeKeep` reference from `swipeFavorite`'s doc-comment on line 120: change `"To explicitly favourite an asset use `swipeFavorite()` or `toggleFavorite(_:)`."` → after Task 10 removes `toggleFavorite`, this whole line will need adjusting; for now leave it and Task 10 handles it. Also delete the "Note: unlike swipeKeep/swipeDelete/swipeFavorite" line at 178 → rewrite as "Note: unlike swipeDelete/swipeFavorite".

- [ ] **Step 2: Migrate test call sites**

Replace in `SessionResumeTests.swift`:
```swift
await m.swipeKeep()   // 0 → decided
await m.swipeKeep()   // 1 → decided → phase transitions to .finished
```
with
```swift
await m.swipeFavorite()   // 0 → decided
await m.swipeFavorite()   // 1 → decided → phase transitions to .finished
```

Replace in `CommitDeletionsTests.swift:18` and `:57`:
```swift
await m.swipeKeep()
```
with
```swift
await m.swipeFavorite()
```

- [ ] **Step 3: Verify no other callers**

Run: `grep -rn "swipeKeep" /home/harshal.patil/Documents/SwipeSort/`
Expected: zero matches. (There should be no matches in the SwipeSort/ tree, tests included.)

---

## Task 2: Rename `GestureMode` cases and rewrite doc-comments to match runtime behavior

**Files:**
- Modify: `SwipeSort/Core/AppSettings.swift:9-16`
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift:236-253` (`swipe(_:using:)`)
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift` — 4 sites, one per switch on `settings.gestureMode`
- Modify: `SwipeSort/Features/Settings/SettingsView.swift:75-82` (display names)
- Modify: any tests in `SwipeSortTests/` that switch on `GestureMode` (grep first)

**Interfaces:**
- Renames: enum case `upDeleteDownKeep` → `upDeleteDownFavorite`; `rightDeleteLeftKeep` → `rightDeleteLeftFavorite`. Raw values stay unchanged (`"upDeleteDownKeep"`, `"rightDeleteLeftKeep"`) to preserve UserDefaults compatibility.

- [ ] **Step 1: Rewrite the enum in `AppSettings.swift`**

Replace lines 9-16 with:
```swift
/// The 4-way gesture configuration mode selected by the user.
///
/// Both modes provide comprehensive 4-way navigation without gesture collisions.
/// The `rawValue` strings are frozen for UserDefaults compatibility — do not
/// rename them even when the Swift case identifier changes.
enum GestureMode: String, CaseIterable, Codable, Sendable {
    /// Mode 1: Up = Delete, Down = Favorite, Right = Prev, Left = Next.
    case upDeleteDownFavorite = "upDeleteDownKeep"
    /// Mode 2: Right = Delete, Left = Favorite, Up = Next, Down = Prev.
    case rightDeleteLeftFavorite = "rightDeleteLeftKeep"
}
```

Note the direction assignments in the doc-comments must match the actual dispatch table in `SwipeSessionModel.swipe(_:using:)`:
- `upDeleteDownFavorite`: up→delete, down→favorite, left→**next**, right→**prev**
- `rightDeleteLeftFavorite`: right→delete, left→favorite, up→next, down→prev

Verify against `SwipeSessionModel.swift:236-253` and edit if they disagree.

- [ ] **Step 2: Migrate every switch site**

Run: `grep -rn "\.upDeleteDownKeep\|\.rightDeleteLeftKeep" /home/harshal.patil/Documents/SwipeSort/`

For each match, rename `.upDeleteDownKeep` → `.upDeleteDownFavorite` and `.rightDeleteLeftKeep` → `.rightDeleteLeftFavorite`. Expected sites:
- `SwipeSessionModel.swift:238,245`
- `SwipeStackView.swift:352,354,428,429,437,445,712,713,732,733`
- Any test files

- [ ] **Step 3: Update `SettingsView.displayName`**

`GestureMode.displayName` at `SettingsView.swift:75-82`:
- Replace the case names in the switch (`case .upDeleteDownKeep: ...`) with the new names.
- Rewrite the strings: `"Mode 1 (Up: Delete, Down: Fav)"` stays as-is — it's already correct — but the "Fav" abbreviation could be spelled out. Recommendation: change to `"Mode 1 — Up Delete, Down Favorite"` and `"Mode 2 — Right Delete, Left Favorite"`. Do this only if the picker still fits; if width is tight, leave the abbreviation and only fix the case rename.

- [ ] **Step 4: Verify raw-value round-trip**

Confirm `AppSettings.readRaw` (line 83) still resolves the old rawValue strings via `T(rawValue:)`. Since we kept `= "upDeleteDownKeep"` on the case, `T(rawValue: "upDeleteDownKeep")` still returns `.upDeleteDownFavorite`. Existing users' settings survive.

Run: `grep -rn "upDeleteDownKeep\|rightDeleteLeftKeep" /home/harshal.patil/Documents/SwipeSort/`
Expected matches: 2 (the `rawValue = ...` declarations only). Every other reference must have been renamed.

---

## Task 3: Remove `SwipeFilter.MediaTypeFilter.livePhotosOnly` dead case

**Files:**
- Modify: `SwipeSort/Core/SwipeFilter.swift:22, 73`

**Interfaces:**
- Removes: enum case `.livePhotosOnly` from `MediaTypeFilter`
- Consumers: none — no code emits or consumes it.

- [ ] **Step 1: Delete the case**

Remove line 22 (`case livePhotosOnly`) from the `MediaTypeFilter` enum.

- [ ] **Step 2: Update the setter switch**

Line 72-83 currently reads:
```swift
switch newValue {
case .any, .livePhotosOnly:
    break
case .photosOnly:
    ...
```

Replace with:
```swift
switch newValue {
case .any:
    break
case .photosOnly:
    ...
```

- [ ] **Step 3: Verify no callers**

Run: `grep -rn "livePhotosOnly" /home/harshal.patil/Documents/SwipeSort/`
Expected: zero matches.

---

## Task 4: Delete `totalPendingCount` synonym

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift:329-330`
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:303`

**Interfaces:**
- Removes: `SwipeSessionModel.totalPendingCount: Int`
- Consumers: 1 (`SwipeStackView.swift:303`)

- [ ] **Step 1: Delete the property**

Remove lines 329-330 (the `/// The number of assets queued for deletion. Equivalent to ...` doc-comment and the `var totalPendingCount: Int { pendingDeletions.count }` line).

- [ ] **Step 2: Migrate the caller**

In `SwipeStackView.swift:303`, change:
```swift
guard model.totalPendingCount > 0, commitResult == nil else { return }
```
to:
```swift
guard !model.pendingDeletions.isEmpty, commitResult == nil else { return }
```
The `.isEmpty` form is equivalent to `.count > 0` (negated) and reads more naturally.

- [ ] **Step 3: Verify no other callers**

Run: `grep -rn "totalPendingCount" /home/harshal.patil/Documents/SwipeSort/`
Expected: zero matches.

---

## Task 5: Delete `DecisionQueue.deleteCount` (and audit `keepCount`)

**Files:**
- Modify: `SwipeSort/Core/SwipeDecision.swift:55-69`
- Modify: `SwipeSortTests/SwipeDecisionQueueTests.swift` — 10+ assertions

**Interfaces:**
- Removes: `DecisionQueue.deleteCount: Int`. Possibly `keepCount` if unused too.
- Consumers: only unit tests.

- [ ] **Step 1: Audit `keepCount`**

Run: `grep -rn "keepCount" /home/harshal.patil/Documents/SwipeSort/SwipeSort/`
If it has zero production callers (only test callers), it goes too. Report the result in the task's completion note.

- [ ] **Step 2: Delete both properties**

Remove `deleteCount` (lines 55-61) and — pending Step 1 audit — `keepCount` (lines 63-69) from `DecisionQueue`.

- [ ] **Step 3: Migrate tests**

In `SwipeDecisionQueueTests.swift`, replace `q.deleteCount == N` with a direct count:
```swift
q.decisions.filter { if case .delete = $0 { true } else { false } }.count == N
```
Or, cleaner, add a private test-only helper at the top of the file:
```swift
private func deleteCount(_ q: DecisionQueue) -> Int {
    q.decisions.reduce(0) { $0 + ((if case .delete = $1 { true } else { false }) ? 1 : 0) }
}
```
and rewrite call sites as `deleteCount(q) == N`. Same for `keepCount` if it was removed.

- [ ] **Step 4: Verify**

Run: `grep -rn "\.deleteCount\|\.keepCount" /home/harshal.patil/Documents/SwipeSort/SwipeSort/`
Expected: zero matches in `SwipeSort/` (tests are allowed to define local helpers with the same name).

---

## Task 6: Extract `isPrevDirection(dx:dy:mode:)` helper in `SwipeStackView`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:346-357, 700-714, 727-734`

**Interfaces:**
- Adds: `private func isPrevDirection(dx: CGFloat, dy: CGFloat, mode: GestureMode) -> Bool`
- Consumers: 3 sites internal to `SwipeStackView`.

- [ ] **Step 1: Add the helper**

Insert near the top of `SwipeStackView` (below the `swipeGesture` computed property, or above it — pick wherever the file's other private helpers live; `hintForDirection` at 425 is a good anchor). Suggested location: just before `hintForDirection` (line 425).

```swift
/// Returns `true` when the given translation, interpreted under `mode`,
/// maps to the "go to previous photo" gesture.
///
/// Extracted from three duplicated switch-on-mode blocks (drag-hint, onChanged, onEnded).
private func isPrevDirection(dx: CGFloat, dy: CGFloat, mode: GestureMode) -> Bool {
    let isVertical = abs(dy) > abs(dx)
    switch mode {
    case .upDeleteDownFavorite:    return !isVertical && dx > 0
    case .rightDeleteLeftFavorite: return isVertical && dy > 0
    }
}
```

- [ ] **Step 2: Replace the three copies**

In `isDraggingPrev` (346-357), rewrite the body:
```swift
private var isDraggingPrev: Bool {
    let dx = dragOffset.width
    let dy = dragOffset.height
    guard abs(dx) > 10 || abs(dy) > 10 else { return false }
    return isPrevDirection(dx: dx, dy: dy, mode: settings.gestureMode)
}
```

In `swipeGesture.onChanged` (700-714), replace the six-line `isPrev` calculation with:
```swift
let isPrev = isPrevDirection(dx: dx, dy: dy, mode: settings.gestureMode)
```

Same in `swipeGesture.onEnded` (727-734).

- [ ] **Step 3: Verify**

The three duplicated `switch settings.gestureMode` blocks that produce an `isPrev` local must be gone. `grep -n "isPrev: Bool" /home/harshal.patil/Documents/SwipeSort/SwipeSort/Features/Swipe/SwipeStackView.swift` expected: zero matches.

---

## Task 7: Drop `durationSeconds` from `SwipeCardView.shouldAutoplay`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeCardView.swift:45, 97-99`
- Modify: `SwipeSortTests/SettingsIntegrationTests.swift:78-95`

**Interfaces:**
- Renames: `shouldAutoplay(durationSeconds:settings:)` → `shouldAutoplay(settings:)`
- Consumers: 1 in-app + 5 in tests.

- [ ] **Step 1: Rewrite the function**

Replace lines 93-99 with:
```swift
/// Returns whether video autoplay should be active for the current setting.
///
/// Static so tests can call it without a hosting SwiftUI view.
static func shouldAutoplay(settings: AppSettings) -> Bool {
    settings.autoplayVideos
}
```

- [ ] **Step 2: Update the in-app call site**

Line 45 changes from `Self.shouldAutoplay(durationSeconds: duration, settings: settings)` to `Self.shouldAutoplay(settings: settings)`. The `duration` local is unused in that scope after the change — check whether it is still bound at line 43 (`case .video(let duration):`) and if it's only used here, change to `case .video:` (drop the binding).

Verify: `case .video(let duration)` at line 43 is used only at line 45 in `shouldAutoplay(...)`. After the change, use `case .video:` (no binding).

- [ ] **Step 3: Update tests**

In `SettingsIntegrationTests.swift`, every call like:
```swift
#expect(SwipeCardView.shouldAutoplay(durationSeconds: 10, settings: s) == true)
```
becomes:
```swift
#expect(SwipeCardView.shouldAutoplay(settings: s) == true)
```

Lines 78, 79, 80, 86, 95. Multi-line tests may have redundancy after this rewrite (e.g., three assertions with different durations all become the same assertion) — de-duplicate: keep one assertion per `settings.autoplayVideos` state (on/off).

---

## Task 8: Hoist duplicate "Go Back" button in `finishedSummary`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:627-655`

- [ ] **Step 1: Replace the duplicated block**

The current structure (lines 627-655) is:
```swift
if model.pendingDeletions.isEmpty || commitResult != nil {
    Button { dismiss() } label: { ... "Go Back" ... }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("GoBackButton")
} else {
    Button { dismiss() } label: { ... "Go Back" ... }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("GoBackButton")
}
```

Replace with a single Button whose style is conditional:
```swift
let goBackIsPrimary = model.pendingDeletions.isEmpty || commitResult != nil
Button {
    dismiss()
} label: {
    HStack(spacing: 8) {
        Image(systemName: "arrow.backward")
        Text("Go Back")
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
}
.if(goBackIsPrimary) { $0.buttonStyle(.borderedProminent) }
.if(!goBackIsPrimary) { $0.buttonStyle(.bordered) }
.accessibilityIdentifier("GoBackButton")
```

If `View.if(_:transform:)` extension isn't already in the codebase (`grep -rn "func \`if\`" SwipeSort/`), don't add one — it's a common footgun (view-identity changes on branch swap). Instead, use two separate `.buttonStyle` applications guarded by an `if` inside a `Group`:

```swift
let goBackIsPrimary = model.pendingDeletions.isEmpty || commitResult != nil
Button { dismiss() } label: {
    HStack(spacing: 8) {
        Image(systemName: "arrow.backward")
        Text("Go Back")
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
}
.buttonStyle(goBackIsPrimary ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
.accessibilityIdentifier("GoBackButton")
```

Where `AnyButtonStyle` is a type-erased `ButtonStyle` wrapper (or use Apple's built-in `AnyShape`-style trick with the two concrete `ButtonStyle` types).

**Simpler alternative** (recommended): keep the `if/else` structure but extract the label into a `@ViewBuilder` computed property `goBackLabel: some View` (shared) so only the `.buttonStyle` differs:

```swift
if model.pendingDeletions.isEmpty || commitResult != nil {
    Button { dismiss() } label: { goBackLabel }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("GoBackButton")
} else {
    Button { dismiss() } label: { goBackLabel }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("GoBackButton")
}
```

Where:
```swift
@ViewBuilder
private var goBackLabel: some View {
    HStack(spacing: 8) {
        Image(systemName: "arrow.backward")
        Text("Go Back")
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
}
```

This eliminates the 12-line label duplication without introducing `AnyButtonStyle` or a fragile `.if` extension. **Use this approach.**

- [ ] **Step 2: Verify**

`grep -c "\"Go Back\"" /home/harshal.patil/Documents/SwipeSort/SwipeSort/Features/Swipe/SwipeStackView.swift`
Expected: 1 (was 2).

---

## Task 9: Remove dead inner `if` in `ReviewCommitView.queueGrid`

**Files:**
- Modify: `SwipeSort/Features/Swipe/ReviewCommitView.swift:64`

- [ ] **Step 1: Remove the redundant guard**

Current (line 61-77):
```swift
private var queueGrid: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            if !model.pendingDeletions.isEmpty {
                Text("Queued for Deletion (\(model.pendingDeletions.count))")
                    .font(.headline)
                    .padding(.horizontal, 16)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(model.pendingDeletions, id: \.rawValue) { id in
                        QueueThumbnailCell(id: id, library: library) {
                            model.removeFromDeletionQueue(id)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}
```

Rewrite as (dedent the two children, remove the `if`):
```swift
private var queueGrid: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Queued for Deletion (\(model.pendingDeletions.count))")
                .font(.headline)
                .padding(.horizontal, 16)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(model.pendingDeletions, id: \.rawValue) { id in
                    QueueThumbnailCell(id: id, library: library) {
                        model.removeFromDeletionQueue(id)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}
```

- [ ] **Step 2: Verify the outer branch guarantees the invariant**

Read lines 18-23 to confirm: `if model.pendingDeletions.isEmpty { emptyState } else { queueGrid }`. The `else` branch is the only caller of `queueGrid`, so `!model.pendingDeletions.isEmpty` is guaranteed at entry.

---

## Task 10: Delete `SwipeSessionModel.toggleFavorite`

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeSessionModel.swift:205-212`
- Modify: any test that calls `toggleFavorite` (grep first)

**Interfaces:**
- Removes: `SwipeSessionModel.toggleFavorite(_:) async -> Bool`
- Consumers: verify via grep.

- [ ] **Step 1: Find callers**

Run: `grep -rn "toggleFavorite" /home/harshal.patil/Documents/SwipeSort/`

Expected: only tests (SwipeSessionModelTests or a dedicated favorite-toggle test) plus one doc-comment self-reference (`swipeFavorite`'s doc-comment at line 120).

- [ ] **Step 2: Delete the method**

Remove `SwipeSessionModel.swift` lines 205-212 (the `/// Sets the Photos favourite flag on the current asset without recording ...` doc-comment plus the `func toggleFavorite(_ isFavorite: Bool) async -> Bool { ... }` body).

- [ ] **Step 3: Fix the stale reference in `swipeFavorite`'s doc**

`SwipeSessionModel.swift:120`:
```swift
/// To explicitly favourite an asset use `swipeFavorite()` or `toggleFavorite(_:)`.
```
After Task 1 removed `swipeKeep`, this comment lives in a doc-comment block that's already being reworked. After Task 10, the entire block is gone (Task 1 removed the whole `swipeKeep` doc-block; there's no other place to have this comment). Verify that no `toggleFavorite` reference remains in comments.

- [ ] **Step 4: Delete or update tests**

For each test found in Step 1, either delete the test (if the whole file is dedicated to `toggleFavorite` — unlikely) or delete only the specific `#expect` / `#test` blocks that exercise it.

- [ ] **Step 5: Verify**

Run: `grep -rn "toggleFavorite" /home/harshal.patil/Documents/SwipeSort/`
Expected: zero matches.

---

## Task 11: Modernise `SettingsView` bindings and simplify `ThemeMode.displayName`

**Files:**
- Modify: `SwipeSort/Features/Settings/SettingsView.swift:10,13,65-73`

- [ ] **Step 1: Update `SettingsView` to modern `@Bindable @Environment`**

Replace:
```swift
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var s = settings
        ...
    }
}
```

With:
```swift
struct SettingsView: View {
    @Environment(AppSettings.self) @Bindable private var settings

    var body: some View {
        ...
    }
}
```

Then rename every `$s.themeMode` → `$settings.themeMode` inside `body`. Same for `$s.gestureMode`, `$s.hapticsEnabled`, `$s.autoplayVideos`, `$s.skipCommitReview`. (`s.skipCommitReview` non-`$` reads in the footer stay as `settings.skipCommitReview`.)

**Compatibility note:** if `@Environment @Bindable` combined syntax is a Swift compiler error (some Swift/Xcode combos are picky), fall back to the property-wrapper composition pattern:

```swift
@Environment(AppSettings.self) private var settings

@State private var bindableSettings: Bindable<AppSettings>?

var body: some View {
    let s = bindableSettings ?? Bindable(settings)
    ...
}
```

But before falling back, try the combined form first — Xcode 15+/Swift 5.9+ supports it.

- [ ] **Step 2: Simplify `ThemeMode.displayName`**

Replace lines 65-73:
```swift
private extension ThemeMode {
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}
```

With:
```swift
private extension ThemeMode {
    var displayName: String { rawValue.capitalized }
}
```

Behavior is identical: `"system".capitalized == "System"`, `"light".capitalized == "Light"`, `"dark".capitalized == "Dark"`.

- [ ] **Step 3: Verify**

Read the file end-to-end to confirm both changes compiled-in-your-head cleanly. `grep -n "@Bindable var s = settings" SwipeSort/` should return zero matches.

---

## Task 12: Rename `ReviewCommitView.swift` → `DeletionQueueView.swift`

**Files:**
- Rename: `SwipeSort/Features/Swipe/ReviewCommitView.swift` → `SwipeSort/Features/Swipe/DeletionQueueView.swift`
- Update: any references in `docs/reviews/2026-07-13/README.md` (file map)

**Note:** without git in this environment, "rename" means:
1. Write the file to the new path with unchanged contents.
2. Delete the old path.

If the environment can't delete files directly, prepend a brief comment inside the old path stating it has moved, but prefer a true rename via `mv` if `Bash` allows.

- [ ] **Step 1: Copy contents to new path**

Read `ReviewCommitView.swift` fully; write to `DeletionQueueView.swift`. Contents unchanged.

- [ ] **Step 2: Remove the old file**

Run: `rm /home/harshal.patil/Documents/SwipeSort/SwipeSort/Features/Swipe/ReviewCommitView.swift`
(Or use whatever file-deletion primitive is available.)

- [ ] **Step 3: Update Xcode project references — DEFER**

The Xcode `project.pbxproj` file lists source files by name; renaming a file requires either editing pbxproj (fragile) or the user re-adds the file in Xcode. Add this to the "manual Xcode steps" section of the phase-7 completion report so the user knows to fix it in Xcode after pulling the changes.

- [ ] **Step 4: Update the review doc**

If `docs/reviews/2026-07-13/README.md` mentions `ReviewCommitView.swift` in its file map, update to `DeletionQueueView.swift`. Grep first: `grep -rn "ReviewCommitView" docs/`

---

## Task 13: Verify already-closed findings and record won't-fix items

**Files:**
- Modify: `docs/reviews/2026-07-13/phase-7-working-set.md` (append verification results)
- Modify: `SwipeSort/Features/Landing/RecentsView.swift:144` — add `// TODO(pagination):` marker
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift:264` — add `// TODO(pagination):` marker
- Modify: `SwipeSort/Core/VideoPlayerPool.swift:46-51` — add `// TODO(iCloud-cancel):` marker

- [ ] **Step 1: Verify Phase-3-closed anchors**

Confirm:
- `SwipePresentationContext` exists at `SwipeSort/Features/Components/SwipePresentationContext.swift` (yes — confirmed in re-verify).
- `AlbumGridView.getScopedLibrary()` no longer exists (confirmed — Phase 3 rewrote to a plain `@State` set via `.task(id:)`).
- `AppSettings.dryRunMode` no longer exists (confirmed — grep returns zero matches).

- [ ] **Step 2: Add pagination TODO markers**

In `RecentsView.swift` around line 143-144:
```swift
// TODO(pagination): the 500-cap silently truncates larger libraries. Replace
// with cursor-based paging once the grid supports appending on scroll.
let limit = min(count, 500)
```

In `AlbumsView.swift` around line 264:
```swift
// TODO(pagination): 1000-cap silently truncates larger albums. See RecentsView.
let limit = min(count, 1000)
```

- [ ] **Step 3: Add VideoPlayerPool cancel TODO**

In `VideoPlayerPool.swift:46-51` (or wherever the LRU eviction lives; grep for `replaceCurrentItem`):
```swift
// TODO(iCloud-cancel): for Photos-managed AVAssets, evicting the slot does
// not cancel the underlying PHImageManager.requestPlayerItem request. Track
// the request ID alongside the Slot and call cancelImageRequest on eviction.
evicted.player.replaceCurrentItem(with: nil)
```

---

## Task 14: Add missing test pins from Phase 5's tail

**Files:**
- Modify: `SwipeSortTests/WindowedThumbnailCacheTests.swift` — add zero-total test
- Modify: `SwipeSortTests/SwipeSessionModelTests.swift` — add `swipePrev` fully-decided test and `removeFromDeletionQueue` test
- Modify: `SwipeSortTests/SettingsIntegrationTests.swift` — add Mode 1 right-prev + Mode 2 down-prev tests
- Modify: `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift` — add launch assertion

**Note:** without an Xcode runtime, these tests are written but cannot be validated in this environment. They are recorded as follow-ups the user must run in Xcode after pulling. Document that in the phase-completion report.

- [ ] **Step 1: WindowedThumbnailCache zero-total**

Add to `WindowedThumbnailCacheTests.swift`:
```swift
@Test("slide with total=0 does not issue any caching calls")
@MainActor func slideZeroTotalIsNoOp() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 0)
    let cache = WindowedThumbnailCache(library: mock, targetSize: CGSize(width: 100, height: 100))
    await cache.slide(to: 0, total: 0)
    #expect(mock.startCachingCalls.isEmpty, "empty library must not issue any startCachingThumbnails calls")
}
```

- [ ] **Step 2: swipePrev when all prior are decided**

Add to `SwipeSessionModelTests.swift`:
```swift
@Test("swipePrev is a no-op when currentIndex is 0")
@MainActor func swipePrevAtStartIsNoOp() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, initialIndex: 0, initialAssetId: nil, targetSize: CGSize(width: 100, height: 100))
    await m.start()
    // Decide all three.
    await m.swipeDelete()
    await m.swipeDelete()
    await m.swipeDelete()
    // Session is now .finished. Navigating back from a finished session is out of scope;
    // the intent of this test is the "at start, prev is a no-op" contract.
    let m2 = SwipeSessionModel(library: mock, initialIndex: 0, initialAssetId: nil, targetSize: CGSize(width: 100, height: 100))
    await m2.start()
    await m2.swipePrev()
    #expect(m2.currentIndex == 0, "swipePrev at index 0 must not underflow")
}
```

- [ ] **Step 3: removeFromDeletionQueue integration test**

Add to `SwipeSessionModelTests.swift`:
```swift
@Test("removeFromDeletionQueue decrements pendingDeletions and preserves other decisions")
@MainActor func removeFromDeletionQueueDecrementsCount() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 5)
    let m = SwipeSessionModel(library: mock, initialIndex: 0, initialAssetId: nil, targetSize: CGSize(width: 100, height: 100))
    await m.start()
    await m.swipeDelete()   // 0 → pending
    await m.swipeDelete()   // 1 → pending
    await m.swipeDelete()   // 2 → pending
    #expect(m.pendingDeletions.count == 3)
    let middle = m.pendingDeletions[1]
    m.removeFromDeletionQueue(middle)
    #expect(m.pendingDeletions.count == 2)
    #expect(!m.pendingDeletions.contains(middle))
}
```

- [ ] **Step 4: Mode 1 right-prev + Mode 2 down-prev**

Add to `SettingsIntegrationTests.swift`:
```swift
@Test("Mode 1: right swipe dispatches to swipePrev")
@MainActor func mode1RightIsPrev() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, initialIndex: 1, initialAssetId: nil, targetSize: CGSize(width: 100, height: 100))
    await m.start()
    let s = AppSettings(defaults: UserDefaults(suiteName: "test-mode1-\(UUID().uuidString)")!)
    s.gestureMode = .upDeleteDownFavorite
    await m.swipe(.right, using: s)
    #expect(m.currentIndex == 0, "right in Mode 1 must swipePrev")
}

@Test("Mode 2: down swipe dispatches to swipePrev")
@MainActor func mode2DownIsPrev() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    let m = SwipeSessionModel(library: mock, initialIndex: 1, initialAssetId: nil, targetSize: CGSize(width: 100, height: 100))
    await m.start()
    let s = AppSettings(defaults: UserDefaults(suiteName: "test-mode2-\(UUID().uuidString)")!)
    s.gestureMode = .rightDeleteLeftFavorite
    await m.swipe(.down, using: s)
    #expect(m.currentIndex == 0, "down in Mode 2 must swipePrev")
}
```

- [ ] **Step 5: UI-test launch assertion**

Replace `SwipeSortUITests/SwipeSortUITestsLaunchTests.swift`'s `testLaunch()` body with an actual assertion:
```swift
func testLaunch() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app failed to reach foreground state")
    // The main tab bar is the root of the app; if it fails to appear, the launch effectively hung.
    XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5), "root tab bar did not appear on launch")
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Launch Screen"
    attachment.lifetime = .keepAlways
    add(attachment)
}
```

- [ ] **Step 6: Note runtime validation caveat**

These tests are code-complete but cannot run in this environment. Add to the phase-7-complete report: "The 5 test additions must be validated by running `xcodebuild test` in Xcode after pulling; if any fails, an adversarial fix wave is required."

---

## Self-review

- **Spec coverage:** every LIVE finding in `phase-7-working-set.md` maps to Task 1–14. F1→T1, F2→T2, F3→T3, F4→T4, F5→T5, F6→T6, F7→T7, F8→T8, F9→T9, F10→T10, F11+F13→T11, F14→T12, F15+F16→T13 (verify), F18→T13 (TODO), F17→T14, plus performance.md F14 covered by T13 TODO.
- **Placeholders:** none.
- **Type consistency:** `GestureMode` case renames apply to every switch site listed in Task 2 Step 2; no `.upDeleteDownKeep` remains. `swipeKeep`, `totalPendingCount`, `deleteCount`, `livePhotosOnly`, `toggleFavorite`, `shouldAutoplay(durationSeconds:)` — all removed with call-site migrations.
- **Backward compatibility:** `UserDefaults` rawValue strings for `GestureMode` are preserved (Global Constraints).
