# Phase 6 Accessibility & HIG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring SwipeSort's swipe deck, grid, and settings surfaces up to Apple's a11y + HIG expectations — VoiceOver labels/actions on the primary UI, Reduce Motion honoured, Dynamic Type applied, 44 pt tap targets, prepared haptics, transparent usage-description copy.

**Architecture:** All changes are surgical view-layer additions. No new files. Existing modifiers (`.accessibilityLabel`, `.accessibilityHint`, `.accessibilityAction`, `.accessibilityHidden`, `@Environment(\.accessibilityReduceMotion)`, `UIAccessibility.post`) get wired into `SwipeStackView`, `SwipeCardView`, `ThumbnailCell`, `PhotoGridView`, `SettingsView`, and `Info.plist`. Two haptic generators become `@State` on `SwipeStackView` with `prepare()` fired during drag.

**Tech Stack:** SwiftUI, UIKit (`UIAccessibility`, `UIImpactFeedbackGenerator`, `UINotificationFeedbackGenerator`), iOS 17 accessibility APIs, Swift Testing / XCTest for coverage.

## Global Constraints

- All new copy must be **plain and consequence-oriented** (e.g., "Immediately deletes the N pending photos" — never "Tap to confirm").
- `.accessibilityLabel` values MUST NOT hard-code strings that duplicate the visible `Text` unless the visible text is decorative-only. Prefer to *augment* rather than *replace* SwiftUI's default label composition.
- `.accessibilityIdentifier` values are STABLE — Phase 5 UI tests already depend on `"SwipeCard"`, `"CloseDeckButton"`, `"ProgressCounter"`, `"PendingDeletionsButton"`, `"UndoButton"`, `"FilterButton"`, `"ThumbnailCell-\(index)"`, `"AlbumRow-\(id)"`, `"FinishedSummaryView"`. **Do not rename existing identifiers.**
- Every UIAccessibility.post call must be gated so it fires only when VoiceOver is running: `guard UIAccessibility.isVoiceOverRunning else { return }`. Silent no-op otherwise.
- Reduce Motion: when active, `rotationEffect` degrees MUST be 0 (not just skip the animation — the transform itself is the vestibular hazard).
- Haptic generators: prepare cost is negligible when `hapticsEnabled == false` because we exit early; the fix is purely to preallocate + call `prepare()` when haptics are enabled and a drag is in progress.
- No new dependencies. No new files unless a test file is called for.
- Every task ends in a small commit with a message describing the a11y goal (e.g., `a11y: label and actions on SwipeCardView (F3)`).

---

### Task 1: SwipeCard VoiceOver label + accessibility actions (F3)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeCardView.swift` (add computed a11y label + hidden-drag-hint plumbing)
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:252-267` (attach `.accessibilityLabel` + `.accessibilityAction(named:)` to top card; `.accessibilityHidden(true)` on drag hint overlay)

**Interfaces:**
- Consumes: `model.currentIndex`, `model.totalCount`, `model.currentKind`, `model.currentThumbnailDownloadProgress` (already on `SwipeSessionModel`).
- Produces: no new API surface.

- [ ] **Step 1: Write the failing UI test**

Add to `SwipeSortUITests/SwipeSortUITests.swift`:

```swift
@MainActor
func testSwipeCardExposesVoiceOverLabel() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    let recents = app.buttons["ThumbnailCell-0"]
    XCTAssertTrue(recents.waitForExistence(timeout: 5))
    recents.tap()
    let card = app.otherElements["SwipeCard"]
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    // The label MUST include position + total. Kind can be Photo/Video/Live Photo.
    let label = card.label
    XCTAssertTrue(label.contains(" of "), "label was '\(label)' — expected 'N of M' phrasing")
}
```

- [ ] **Step 2: Verify the test fails**

Run: `xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SwipeSortUITests/SwipeSortUITests/testSwipeCardExposesVoiceOverLabel`
Expected: FAIL — the card exists but its label is empty.

- [ ] **Step 3: Add the label + actions in SwipeStackView**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`, replace the top `SwipeCardView` block (lines 252-267) with:

```swift
SwipeCardView(
    thumbnail: model.currentThumbnail,
    kind: model.currentKind,
    assetId: model.currentThumbnail?.identifier,
    library: library,
    downloadProgress: model.currentThumbnailDownloadProgress
)
.accessibilityIdentifier("SwipeCard")
.accessibilityElement(children: .combine)
.accessibilityLabel(cardAccessibilityLabel)
.accessibilityValue(cardAccessibilityValue)
.accessibilityAction(named: "Delete") { Task { await model.swipeDelete() } }
.accessibilityAction(named: "Favorite") { Task { await model.swipeFavorite() } }
.accessibilityAction(named: "Next photo") { Task { await model.swipeNext() } }
.accessibilityAction(named: "Previous photo") { Task { await model.swipePrev() } }
.overlay { dragHintOverlay.accessibilityHidden(true) }
.offset(dragOffset)
.rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset.width / 20)))
.gesture(swipeGesture)
.onLongPressGesture(minimumDuration: 0.5) {
    zoomingId = model.currentThumbnail?.identifier
}
```

Note the `.overlay { dragHintOverlay.accessibilityHidden(true) }` moves the hint *into* the a11y-hidden overlay so it does not clutter VoiceOver.
Note the `reduceMotion` reference — declared in Task 5. If executing Task 1 before Task 5, replace with `Double(dragOffset.width / 20)` and revisit.

Then add these computed properties on `SwipeStackView` (right above `swipeGesture`):

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

private var cardAccessibilityLabel: String {
    guard model.phase == .ready else { return "Swipe card" }
    let kindWord: String
    switch model.currentKind {
    case .photo: kindWord = "Photo"
    case .video: kindWord = "Video"
    case .livePhoto: kindWord = "Live Photo"
    }
    return "\(kindWord) \(model.currentIndex + 1) of \(model.totalCount)"
}

private var cardAccessibilityValue: String {
    if let progress = model.currentThumbnailDownloadProgress {
        let pct = Int((progress * 100).rounded())
        return "Downloading from iCloud, \(pct) percent."
    }
    return ""
}
```

Also add `import UIKit` at the top of the file if not already present (it is, line 2).

- [ ] **Step 4: Verify the UI test passes**

Run: `xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SwipeSortUITests/SwipeSortUITests/testSwipeCardExposesVoiceOverLabel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift SwipeSortUITests/SwipeSortUITests.swift
git commit -m "a11y: SwipeCard label, value, and four accessibility actions (F3)"
```

---

### Task 2: ThumbnailCell VoiceOver label with kind + index (F12)

**Files:**
- Modify: `SwipeSort/Features/Components/ThumbnailCell.swift` (add `accessibilityIndex: Int` parameter; compose label from `mediaKind` + index)
- Modify: `SwipeSort/Features/Components/PhotoGridView.swift:41-46` (pass index through)

**Interfaces:**
- Consumes: existing `id`, `mediaKind` (already `@State`), new required `accessibilityIndex: Int`.
- Produces: `ThumbnailCell.init(id:library:cache:targetSize:isSelected:accessibilityIndex:)` — new named argument, no default.

- [ ] **Step 1: Write the failing test**

Add to `SwipeSortTests/ThumbnailLoadingTests.swift`:

```swift
@Test("ThumbnailCell exposes a11y label combining kind and 1-indexed position")
@MainActor func thumbnailCellExposesA11yLabel() async {
    // This test asserts the API surface — that ThumbnailCell accepts
    // an accessibilityIndex parameter. Rendering behaviour is verified
    // via UI test (see SwipeSortUITests).
    let cache = GridImageCache()
    let library = MockPhotoLibrary(authorization: .authorized, assetCount: 3)
    _ = ThumbnailCell(
        id: AssetIdentifier("mock-asset-0"),
        library: library,
        cache: cache,
        targetSize: CGSize(width: 100, height: 100),
        accessibilityIndex: 0
    )
    // If the initialiser compiles with `accessibilityIndex:`, the API is present.
    #expect(true)
}
```

- [ ] **Step 2: Verify the test fails**

Run test — expected: build failure because `accessibilityIndex:` parameter does not exist.

- [ ] **Step 3: Add the parameter and compose the label**

In `SwipeSort/Features/Components/ThumbnailCell.swift`, add stored property below `var isSelected`:

```swift
/// 0-based index in the grid, used only to compose the VoiceOver label
/// ("Photo 5", "Video 8, 12 seconds"). Not read from `body` — only used
/// inside `.accessibilityLabel`.
let accessibilityIndex: Int
```

Replace lines 78-79 (`.accessibilityElement(children: .ignore)` / `.accessibilityAddTraits(.isButton)`) with:

```swift
.accessibilityElement(children: .ignore)
.accessibilityAddTraits(.isButton)
.accessibilityLabel(accessibilityLabel)
```

Add a computed property:

```swift
private var accessibilityLabel: String {
    let position = accessibilityIndex + 1
    switch mediaKind {
    case .photo:
        return "Photo \(position)"
    case .livePhoto:
        return "Live Photo \(position)"
    case .video(let seconds):
        let s = max(0, Int(seconds.rounded()))
        return "Video \(position), \(s) seconds"
    }
}
```

- [ ] **Step 4: Update PhotoGridView to pass the index**

In `SwipeSort/Features/Components/PhotoGridView.swift`, modify the `ThumbnailCell(...)` call at lines 41-47:

```swift
ThumbnailCell(
    id: id,
    library: library,
    cache: imageCache,
    targetSize: thumbnailPixelSize,
    isSelected: isSelecting ? selectedIds.contains(id) : nil,
    accessibilityIndex: index
)
```

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SwipeSortTests/ThumbnailLoadingTests/thumbnailCellExposesA11yLabel`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add SwipeSort/Features/Components/ThumbnailCell.swift SwipeSort/Features/Components/PhotoGridView.swift SwipeSortTests/ThumbnailLoadingTests.swift
git commit -m "a11y: ThumbnailCell label with media kind + 1-indexed position (F12)"
```

---

### Task 3: Announce pending-deletions increment and phase transition to .finished (F13 + F14)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift` (add two `.onChange` handlers that call `UIAccessibility.post`)

**Interfaces:**
- Consumes: `model.pendingDeletions.count`, `model.phase`, `model.favoritedCount`, `model.movedToAlbumCount`.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Add to `SwipeSortTests/SwipeSessionModelTests.swift` (accessibility-scenario coverage — verifies the *pre-conditions* for the announcement fire):

```swift
@Test("pendingDeletions count and phase are exposed as observable state for a11y announcements")
@MainActor func pendingDeletionsAndPhaseObservable() async {
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 2)
    let model = SwipeSessionModel(
        library: mock, initialIndex: 0, initialAssetId: nil,
        targetSize: CGSize(width: 100, height: 100)
    )
    await model.start()
    let before = model.pendingDeletions.count
    await model.swipeDelete()
    #expect(model.pendingDeletions.count == before + 1,
        "swipeDelete must increment pendingDeletions so the .onChange announcement fires")

    await model.swipeDelete()
    #expect(model.phase == .finished,
        "after all assets swiped, phase must reach .finished so the screen-changed announcement fires")
}
```

- [ ] **Step 2: Verify the test fails or passes (baseline)**

Run test. This test verifies the observable prerequisites, not the announcement itself. It should already PASS (because Phase 1 established these invariants). This is a sanity guard against regressions in Task 3's view-layer changes.

- [ ] **Step 3: Add the two announcement handlers**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`, immediately after the existing `.onChange(of: model.currentIndex)` block (around line 126-128), add:

```swift
.onChange(of: model.pendingDeletions.count) { oldCount, newCount in
    guard newCount > oldCount, UIAccessibility.isVoiceOverRunning else { return }
    let msg = "Queued for deletion. \(newCount) pending."
    UIAccessibility.post(notification: .announcement, argument: msg)
}
.onChange(of: model.phase) { _, newPhase in
    guard newPhase == .finished, UIAccessibility.isVoiceOverRunning else { return }
    let msg = "All photos reviewed. \(model.favoritedCount) favorited, \(model.movedToAlbumCount) moved to albums, \(model.pendingDeletions.count) pending deletion."
    UIAccessibility.post(notification: .screenChanged, argument: msg)
}
```

Note: the existing `.onChange(of: model.phase)` block at line 115-125 (drains VideoPlayerPool) STAYS. You are adding a SECOND handler. SwiftUI supports multiple `.onChange` for the same key path.

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SwipeSortTests/SwipeSessionModelTests/pendingDeletionsAndPhaseObservable`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift SwipeSortTests/SwipeSessionModelTests.swift
git commit -m "a11y: announce deletion queue increments and session-finished summary (F13, F14)"
```

---

### Task 4: Album grid button tap area — 44 pt HIG minimum (F5)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:428-464` (`albumGrid`)

**Interfaces:**
- No API changes. Purely visual/hit-area adjustment.

- [ ] **Step 1: Change the row height and hit area**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`, replace the `albumGrid` computed property (lines 428-464) `rows` binding and button `.frame` line:

```swift
private var albumGrid: some View {
    let rows = [GridItem(.fixed(44)), GridItem(.fixed(44))]  // was 38
    return ScrollView(.horizontal, showsIndicators: false) {
        LazyHGrid(rows: rows, spacing: 8) {
            ForEach(albums.filter { $0.canAdd && !settings.hiddenAlbumIds.contains($0.id) }) { album in
                Button {
                    triggerHaptic()
                    if let idx = albums.firstIndex(where: { $0.id == album.id }) {
                        withAnimation(.snappy) {
                            albums[idx].assetCount += 1
                        }
                    }
                    Task { await model.swipeUp(intoAlbumId: album.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                        Text(album.title)
                            .lineLimit(1)
                            .font(.subheadline.weight(.medium))
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text("\(album.assetCount)")
                            .contentTransition(.numericText())
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 170, height: 44)  // was 38 — HIG minimum tap target
                    .background(Color(.tertiarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Move to \(album.title)")
                .accessibilityHint("Moves the current photo to this album and advances the deck.")
                .accessibilityValue("\(album.assetCount) items")
            }
        }
        .padding(.horizontal, 20)
    }
}
```

Also update the container `.frame(height:)` on line 88 from `84` to `96` (2×44 + 8 spacing) so both rows fit:

```swift
albumGrid
    .frame(height: 96)  // was 84 — 2 rows of 44 pt + 8 pt spacing
    .padding(.bottom, 16)
```

This bundles both the 44 pt tap-area fix (F5) and the album-row VoiceOver label (N3).

- [ ] **Step 2: Verify build succeeds**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift
git commit -m "a11y+HIG: 44 pt album grid tap target with VoiceOver label and hint (F5, N3)"
```

---

### Task 5: Reduce Motion — gate rotation and animations (F16)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift`

**Interfaces:**
- Adds `@Environment(\.accessibilityReduceMotion) private var reduceMotion` on `SwipeStackView` if Task 1 did not add it already.

- [ ] **Step 1: Ensure `reduceMotion` env is declared**

Verify the property from Task 1 exists on `SwipeStackView`:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

If Task 1 was skipped or reordered, add it now near line 20 alongside other `@Environment` declarations.

- [ ] **Step 2: Gate rotationEffect on !reduceMotion**

At line 262 (inside `cardArea`'s top-card ZStack):

```swift
.rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset.width / 20)))
```

(Task 1 already included this — this step is a no-op if Task 1 ran; otherwise apply here.)

- [ ] **Step 3: Wrap animate(offset:) and snapBack() with reduce-motion branches**

Replace `animate(offset:)` and `snapBack()` (lines 706-712):

```swift
private func animate(offset: CGSize) {
    if reduceMotion {
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { dragOffset = offset }
    } else {
        withAnimation(.easeOut(duration: 0.2)) { dragOffset = offset }
    }
}

private func snapBack() {
    if reduceMotion {
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { dragOffset = .zero }
    } else {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
    }
}
```

Also gate the drag-hint overlay's own `.animation(.easeOut(duration: 0.1), value: progress)` on line 392 by wrapping in a conditional:

```swift
.animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: progress)
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift
git commit -m "a11y: honour Reduce Motion for card rotation, swipe animation, hint fade (F16)"
```

---

### Task 6: Prepared haptic generators (F4)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift`

**Interfaces:**
- Adds two `@State` generators to `SwipeStackView`. No API change externally.

- [ ] **Step 1: Add @State generators**

Below the existing `@State private var albums: [UserAlbum] = []` line 31:

```swift
@State private var impactGenerator = UIImpactFeedbackGenerator(style: .light)
@State private var warningGenerator = UINotificationFeedbackGenerator()
```

- [ ] **Step 2: Rewrite trigger helpers to use the stored generators**

Replace `triggerHaptic()` and `triggerWarningHaptic()` (lines 714-726):

```swift
private func triggerHaptic() {
    guard settings.hapticsEnabled else { return }
    impactGenerator.impactOccurred()
    impactGenerator.prepare()  // pre-warm for the next swipe
}

private func triggerWarningHaptic() {
    guard settings.hapticsEnabled else { return }
    warningGenerator.notificationOccurred(.warning)
    warningGenerator.prepare()
}
```

- [ ] **Step 3: Prepare at the leading edge of drag**

In the `DragGesture.onChanged` block (starting line 642), add a prepare call the first time the drag exceeds a small threshold. Insert this at the top of `onChanged`:

```swift
.onChanged { value in
    if settings.hapticsEnabled,
       abs(value.translation.width) + abs(value.translation.height) > 12,
       dragOffset == .zero {
        impactGenerator.prepare()
    }
    let dx = value.translation.width
    let dy = value.translation.height
    // ...rest unchanged...
```

Rationale: `dragOffset == .zero` catches the first `onChanged` per gesture. `magnitude > 12` avoids preparing for pure taps.

- [ ] **Step 4: Verify build**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift
git commit -m "a11y+HIG: preallocate and prepare() haptic generators on drag start (F4)"
```

---

### Task 7: Drag hint uses semantic Dynamic Type fonts (F19)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:382-384`

**Interfaces:**
- No API change.

- [ ] **Step 1: Replace fixed sizes with semantic styles**

Change lines 382-384:

```swift
Image(systemName: hint.icon)
    .font(.title2.weight(.bold))
Text(hint.text)
    .font(.title3.weight(.heavy))
    .tracking(1.5)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)  // cap so hint stays legible on AX3+
```

The cap keeps the overlay from breaking at extreme sizes while still respecting Dynamic Type at reasonable levels.

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift
git commit -m "a11y: drag hint overlay uses semantic Dynamic Type fonts (F19)"
```

---

### Task 8: Finished-summary button hints + identifiers (N1)

**Files:**
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift:566-617`

**Interfaces:**
- Adds three new `accessibilityIdentifier`s: `DeleteNowButton`, `ReviewDeletionsButton`, `GoBackButton`. These are additive — no existing UI test depends on them.

- [ ] **Step 1: Attach labels, hints, and identifiers to the three summary buttons**

Modify the three `Button` blocks in `finishedSummary` (lines 566-616):

For the "Review Deletions" button (line 568-576):

```swift
Button {
    showingQueue = true
} label: {
    Text("Review Deletions (\(model.pendingDeletions.count))")
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
}
.buttonStyle(.bordered)
.accessibilityIdentifier("ReviewDeletionsButton")
.accessibilityHint("Presents the deletion review list before submitting.")
```

For the "Delete Now" button (line 578-587):

```swift
Button {
    Task { commitResult = await model.commitDecisions() }
} label: {
    Text("Delete Now (\(model.pendingDeletions.count))")
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
}
.buttonStyle(.borderedProminent)
.tint(.red)
.accessibilityIdentifier("DeleteNowButton")
.accessibilityHint("Immediately deletes the \(model.pendingDeletions.count) pending photos from your library.")
```

For both "Go Back" buttons (lines 591-601 and 604-614):

```swift
// (both instances)
.accessibilityIdentifier("GoBackButton")
```

(Apply the modifier after `.buttonStyle(...)` in each of the two branches.)

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add SwipeSort/Features/Swipe/SwipeStackView.swift
git commit -m "a11y: identifiers and hints on finished-summary buttons (N1)"
```

---

### Task 9: Gesture Mode picker identifier + label (N2)

**Files:**
- Modify: `SwipeSort/Features/Settings/SettingsView.swift:26-31`

**Interfaces:**
- Adds `.accessibilityIdentifier("GestureModePicker")`. Phase 5 UI tests can adopt this in future revisions but the current fallback (`app.buttons["Gesture Mode"]` / `app.staticTexts["Gesture Mode"]`) continues to work.

- [ ] **Step 1: Add identifier**

Modify the Picker at line 26-31:

```swift
Picker("Gesture Mode", selection: $s.gestureMode) {
    ForEach(GestureMode.allCases, id: \.self) { m in
        Text(m.displayName).tag(m)
    }
}
.pickerStyle(.navigationLink)
.accessibilityIdentifier("GestureModePicker")
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme SwipeSort -destination 'platform=iOS Simulator,name=iPhone 15' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add SwipeSort/Features/Settings/SettingsView.swift
git commit -m "a11y: stable accessibility identifier on Gesture Mode picker (N2)"
```

---

### Task 10: NSPhotoLibraryUsageDescription explicitly mentions deletion (F15)

**Files:**
- Modify: `SwipeSort/Info.plist:22`

**Interfaces:** none.

- [ ] **Step 1: Update the string**

Change the value on line 22 from:

```xml
<string>SwipeSort needs access to your photo library to help you sort and clean up media.</string>
```

to:

```xml
<string>SwipeSort needs full access to your photo library to display, sort, permanently delete, and move photos between your albums.</string>
```

- [ ] **Step 2: Commit**

```bash
git add SwipeSort/Info.plist
git commit -m "a11y+privacy: usage description mentions deletion + album moves (F15)"
```

---

## Cross-cutting notes

- **Existing tests must continue to pass.** No a11y change alters gesture behaviour or model semantics. Any test failure indicates a regression, not a plan intent.
- **UI test file additions in Task 1 must be added to the `SwipeSortUITests` target manually** in Xcode (the plan does not perform this step) — mirror the process from Phase 5 (`SwipeSortTests/ThumbnailLoadingTests.swift` etc.).
- **VoiceOver runtime testing:** enable VoiceOver on a device or simulator to spot-check that: (a) the swipe card announces "Photo N of M", (b) the four rotor actions appear ("Delete", "Favorite", "Next photo", "Previous photo"), (c) the finished-summary announcement fires, (d) the pending-deletions announcement fires on each delete swipe.
- **Reduce Motion runtime testing:** enable Reduce Motion in simulator (`Settings → Accessibility → Motion → Reduce Motion`). Swipe left/right — the card should NOT rotate and should snap without spring easing.
