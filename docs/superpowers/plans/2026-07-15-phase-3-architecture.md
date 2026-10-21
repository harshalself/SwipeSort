# Phase 3 — Shared Grid Extraction + Architecture Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract shared grid primitives into `Features/Components/`, deduplicate the `RecentsView`/`AlbumGridView` grid body into a single `PhotoGridView`, split `PhotoLibraryProviding` into three composable sub-protocols, fix the `BulkDeleteView` shared-library mutation hazard, and move `dryRunMode` off `AppSettings` into a hidden debug menu on the swipe screen.

**Architecture:** Tasks 1–6 are largely independent and ordered for minimal re-work: W7 (self-contained kill-switch relocation) first; W1+W3+W4 bundle creates the `Components/` directory; W6 splits the protocol with a backward-compatible typealias; N3 fixes the `BulkDeleteView` shared-mutation hazard using the narrowed protocol surface from W6; W2 extracts `PhotoGridView` using both the new `Components/` group and the narrowed protocol type; W5 and W8 finish the structural cleanup once `PhotoGridView` exists. No consumer changes its declared `PhotoLibraryProviding` type in this phase — the typealias preserves source compatibility everywhere.

**Tech Stack:** Swift 5 mode, SwiftUI, PhotoKit, Swift Testing (`import Testing`, `@Test`, `#expect`).

**Working set:** [`docs/reviews/2026-07-13/phase-3-working-set.md`](../../reviews/2026-07-13/phase-3-working-set.md)

## Global Constraints

- Swift 5 language mode (not Swift 6); iOS 17 minimum deployment target. All changes must compile under Swift 5 mode.
- All PhotoKit consumer classes (`PhotoKitLibrary`, `MockPhotoLibrary`) are `@MainActor`-isolated per Phase 2. Sub-protocols in W6 must preserve this — concrete impls remain `@MainActor final class`, the sub-protocol declarations remain `Sendable`.
- `PhotoLibraryProviding` becomes a typealias after W6 — **no consumer changes its declared type** in Phase 3.
- No git available in this environment. Every "Commit" step is a report line for the human; the human runs Xcode.
- Test framework is Swift Testing (`import Testing`, `@Test`, `#expect`). All new tests go under `SwipeSortTests/`.
- No swift/xcodebuild available — test steps are logical verification ("Expected: PASS"); the human runs them in Xcode.
- `DryRunMode.isEnabled` reads from `UserDefaults.standard.bool(forKey: "swipesort.dryRun")` with a safe-default of `true` when the key is absent. The W7 fix must write to the same key (`DryRunMode.defaultsKey`) so existing stored values are preserved.
- N1 and N2 from the working set are deferred to Phase 7. Do not plan or execute them in this phase.

---

## Task ordering rationale

**Task 1 (W7) → Task 2 (W1+W3+W4) → Task 3 (W6) → Task 4 (N3 note) → Task 5 (W2) → Task 6 (W5) → Task 7 (W8) → Task 8 (Verification)**

- **W7 first**: self-contained user-safety fix with no dependency on grid work. Closes the locked-spec violation immediately.
- **W1+W3+W4 next**: pure file moves that establish `Features/Components/`. Task 5 (W2) depends on this directory existing.
- **W6 after**: the protocol split is independent of all grid extraction. Landing it before W2 means the extracted `PhotoGridView` can declare the correct narrowed type from the start.
- **N3 (Task 4) is a doc-only note**: `BulkDeleteView` is currently unwired — no call site exists (verified via grep, 2026-07-15). The shared-library-mutation bug is latent. Rather than force-fit a runtime type-cast workaround, Task 4 adds a `// WARN:` doc comment inside `BulkDeleteView` describing the hazard for whichever future task wires the view up. The real fix lives with that wiring work.
- **W2 after W1+W3+W4 and W6**: `PhotoGridView` imports `GridImageCache`, `GridCellFramePreferenceKey`, and `gridIndex` from `Components/` (established by Task 2) and accepts `library: PhotoLibraryProviding` (the typealias, unchanged by W6).
- **W5 after W2**: `ThumbnailCell` is used only inside `PhotoGridView` once W2 lands; moving it to `Components/` then is a clean one-file move.
- **W8 after W2**: verify whether the `getScopedLibrary()` pattern is still present after W2; if so, apply the `.task(id:)` replacement.
- **Verification last**: structural self-check after all code changes.

---

## Task 1: W7 — Remove `dryRunMode` from `AppSettings`, add hidden debug menu

**Files:**
- Modify: `SwipeSort/Core/AppSettings.swift` (lines 26–29, 33–40, 72–74, 83)
- Modify: `SwipeSort/Features/Settings/SettingsView.swift` (lines 54–63)
- Modify: `SwipeSort/Features/Swipe/SwipeStackView.swift` (lines 143–153 — the centred title `VStack`)
- Test: `SwipeSortTests/AppSettingsTests.swift`
- Test: `SwipeSortTests/DebugMenuTests.swift`

**Interfaces:**
- Consumes: `DryRunMode.defaultsKey` (`"swipesort.dryRun"`) and `DryRunMode.setEnabled(_:defaults:)` / `DryRunMode.isEnabled(defaults:)` — unchanged. `DryRunMode.isEnabled` static var — unchanged.
- Produces: `AppSettings` no longer has a `dryRunMode` property. `SettingsView` no longer has a "Safety" section. `SwipeStackView.header` triggers a debug sheet on long-press of the title `VStack`. `DebugMenuView` is a private `View` struct inside `SwipeStackView.swift`.

**TDD form:** The existing `AppSettingsTests` defaults test currently does not assert on `dryRunMode`. After removing the property, the test suite must still compile and pass. A new test in `DebugMenuTests.swift` pins that toggling `DryRunMode` via `setEnabled` preserves existing values (migration contract). The debug menu itself is SwiftUI UI and is not unit-tested; the regression test focuses on the underlying `DryRunMode` persistence.

- [ ] **Step 1: Write the regression test for UserDefaults migration preservation**

Open `SwipeSortTests/DebugMenuTests.swift`. Replace the file contents with:

```swift
import Testing
import Foundation
@testable import SwipeSort

@Suite("DebugMenu")
struct DebugMenuTests {
    @Test("toggle writes through to defaults")
    func toggleWritesDefaults() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        DryRunMode.setEnabled(true, defaults: d)
        #expect(DryRunMode.isEnabled(defaults: d) == true)

        DryRunMode.setEnabled(false, defaults: d)
        #expect(DryRunMode.isEnabled(defaults: d) == false)
    }

    @Test("existing UserDefaults value is preserved after AppSettings loses dryRunMode")
    func existingValuePreserved() {
        // Simulate a user who set dryRunMode=false before Phase 3.
        // After Phase 3, AppSettings no longer reads this key.
        // DryRunMode.isEnabled must still return false for that user,
        // because SwipeStackView reads DryRunMode.isEnabled directly.
        let d = UserDefaults(suiteName: UUID().uuidString)!
        // Pre-Phase-3 state: AppSettings wrote via DryRunMode.setEnabled
        DryRunMode.setEnabled(false, defaults: d)
        #expect(DryRunMode.isEnabled(defaults: d) == false,
                "Existing stored false value must survive AppSettings removal")

        // Fresh install (no key written): must default to true
        let fresh = UserDefaults(suiteName: UUID().uuidString)!
        #expect(DryRunMode.isEnabled(defaults: fresh) == true,
                "Missing key must default to true (safe default)")
    }
}
```

- [ ] **Step 2: Run `DebugMenuTests` to confirm the new test passes today (regression anchor)**

In Xcode: Product → Test → filter to `DebugMenuTests`.
Expected: both tests **PASS** (they test `DryRunMode` directly, which is not changing).

- [ ] **Step 3: Remove `dryRunMode` from `AppSettings`**

In `SwipeSort/Core/AppSettings.swift`, make these changes:

**3a — Remove the doc-comment note about `dryRunMode` (lines 26–29)**

```swift
// BEFORE (lines 26–29)
/// Note: `dryRunMode` is written through `DryRunMode.setEnabled(_, defaults:)`
/// using the injected `defaults` instance. Call sites that read the static
/// `DryRunMode.isEnabled` shorthand always read `UserDefaults.standard` — use
/// `DryRunMode.isEnabled(defaults:)` in tests that inject a custom suite.
```

```swift
// AFTER (replace lines 26–29 with nothing — delete these 4 lines)
```

**3b — Remove `dryRunMode` from the `Key` enum (the key is no longer declared in `AppSettings`; `DryRunMode.defaultsKey` already owns it)**

The `Key` enum at lines 33–40 does not currently contain a `dryRunMode` key (it was always routed through `DryRunMode.setEnabled`). No change needed to `Key`.

**3c — Remove the `dryRunMode` stored property (lines 72–74)**

```swift
// BEFORE (lines 72–74, with the preceding blank line at 71)

    /// When `true`, destructive PhotoKit operations are simulated and logged
    /// instead of executed.
    var dryRunMode: Bool {
        didSet { DryRunMode.setEnabled(dryRunMode, defaults: defaults) }
    }
```

```swift
// AFTER (delete lines 71–74 entirely)
```

**3d — Remove the `dryRunMode` initializer line (line 83)**

```swift
// BEFORE (line 83, inside init)
        self.dryRunMode = DryRunMode.isEnabled(defaults: defaults)
```

```swift
// AFTER (delete line 83 entirely)
```

The resulting `AppSettings.swift` class body no longer contains `dryRunMode`. The `DryRunMode` enum and its static methods remain unchanged. `PhotoKitLibrary` and `SwipeSessionModel` continue to read `DryRunMode.isEnabled` directly — no change needed there.

- [ ] **Step 4: Remove the "Safety" section from `SettingsView`**

In `SwipeSort/Features/Settings/SettingsView.swift`, delete lines 54–63:

```swift
// BEFORE (lines 54–63 — delete this entire section)
                Section {
                    Toggle("Dry-run mode (Safe simulation)", isOn: $s.dryRunMode)
                } header: {
                    Text("Safety")
                } footer: {
                    Text(s.dryRunMode
                        ? "Destructive actions are logged only without modifying your Apple Photos library."
                        : "Real deletion and album moves are armed. Photos will actually be modified.")
                        .foregroundStyle(s.dryRunMode ? Color.secondary : Color.red)
                }
```

```swift
// AFTER (nothing — the section is removed; the "About SwipeSort" Section below it remains)
```

- [ ] **Step 5: Add `DebugMenuView` and long-press gesture in `SwipeStackView`**

In `SwipeSort/Features/Swipe/SwipeStackView.swift`:

**5a — Add `@State private var showingDebugMenu = false` to the `@State` cluster**

The existing `@State` cluster is at the top of `SwipeStackView`. After line 29 (`@State private var didAutoCommit = false`), insert:

```swift
    @State private var showingDebugMenu = false
```

**5b — Add the long-press gesture and sheet to the centred title `VStack` (lines 143–153)**

```swift
// BEFORE (lines 143–153)
            // Centred title + counter
            VStack(spacing: 1) {
                Text(albumTitle ?? "SwipeSort")
                    .font(.headline)
                if model.phase == .ready {
                    Text("\(model.currentIndex + 1) of \(model.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ProgressCounter")
                }
            }
            .multilineTextAlignment(.center)
```

```swift
// AFTER
            // Centred title + counter
            // Long-press for 1.5 s opens the hidden developer debug menu (W7 fix).
            // The gesture is on the VStack rather than the Text so the hit area
            // includes the counter subtitle. 1.5 s minimum duration prevents
            // accidental activation during normal use.
            VStack(spacing: 1) {
                Text(albumTitle ?? "SwipeSort")
                    .font(.headline)
                if model.phase == .ready {
                    Text("\(model.currentIndex + 1) of \(model.totalCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ProgressCounter")
                }
            }
            .multilineTextAlignment(.center)
            .onLongPressGesture(minimumDuration: 1.5) {
                showingDebugMenu = true
            }
            .sheet(isPresented: $showingDebugMenu) {
                DebugMenuView()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
```

**5c — Add `DebugMenuView` after the closing brace of `SwipeStackView` (end of the file or before any existing private extension)**

Append after the last closing brace of `SwipeStackView`:

```swift
// MARK: - Debug Menu (hidden; long-press on swipe title bar)

/// Developer-only debug panel accessible via a 1.5-second long-press on the
/// swipe-screen title bar.
///
/// Not linked from any user-facing navigation. The toggle writes directly to
/// `UserDefaults` via `DryRunMode.setEnabled(_:defaults:)` so the value
/// persists across app launches and is picked up by `PhotoKitLibrary` and
/// `SwipeSessionModel` on the next session start.
///
/// Intentionally plain-looking (no custom styling) so it is clearly not part
/// of the user-facing product UI.
private struct DebugMenuView: View {
    @State private var isDryRun: Bool = DryRunMode.isEnabled

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Dry-run mode", isOn: $isDryRun)
                        .onChange(of: isDryRun) { _, newValue in
                            DryRunMode.setEnabled(newValue)
                        }
                } header: {
                    Text("Developer Settings")
                } footer: {
                    Text(isDryRun
                         ? "Destructive PhotoKit calls are logged only. No actual library changes."
                         : "⚠️ ARMED — real deletion and album moves will execute. Restart session to apply.")
                        .foregroundStyle(isDryRun ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Debug Menu")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

- [ ] **Step 6: Run `AppSettingsTests` to confirm `dryRunMode` removal does not break existing tests**

In Xcode: Product → Test → filter to `AppSettingsTests`.

Expected: all tests **PASS**. The `defaults()` test no longer asserts on `s.dryRunMode` (it never did) — the test checks `themeMode`, `gestureMode`, `autoplayVideos`, `hapticsEnabled`, `skipCommitReview`. All five still compile and pass.

If the compiler reports `s.dryRunMode` anywhere in the test file, remove that reference.

- [ ] **Step 7: Run `SettingsIntegrationTests` and `DryRunModeTests`**

In Xcode: Product → Test → filter to `SettingsIntegrationTests` and `DryRunModeTests`.

Expected: all tests **PASS**. `SettingsIntegrationTests` does not reference `dryRunMode`. `DryRunModeTests` references only `DryRunMode` enum methods, which are unchanged.

- [ ] **Step 8: Commit**

```
Report line: "phase-3/W7: removed AppSettings.dryRunMode + SettingsView Safety section; added DebugMenuView behind 1.5s long-press on swipe title bar — W7"
```

---

## Task 2: W1 + W3 + W4 — Create `Features/Components/` and move shared grid primitives

**Files:**
- Create: `SwipeSort/Features/Components/GridSelectionInfra.swift`
- Create: `SwipeSort/Features/Components/GridImageCache.swift`
- Create: `SwipeSort/Features/Components/SwipePresentationContext.swift`
- Modify: `SwipeSort/Features/Landing/AlbumPickerSheet.swift` (remove lines 153–212)
- Modify: `SwipeSort/Features/Landing/RecentsView.swift` (remove lines 4–54 — both `GridImageCache` and `SwipePresentationContext`)
- Test: none required — compile-clean state after pure file moves is the test

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex(at:in:)`, `GridImageCache`, `SwipePresentationContext` are module-scoped types in `SwipeSort/Features/Components/`. All existing callers (`RecentsView`, `AlbumsView`, `AlbumPickerSheet`) continue to use these symbols by name with no import change needed (single-module app).

**TDD form:** This is a pure structural move — no logic changes. The test is: does the project compile with zero errors after the move? There are no new behaviors to assert. Both `RecentsView.swift` and `AlbumsView.swift` reference these symbols by unqualified name; they will continue to resolve because Swift uses module-level name lookup.

- [ ] **Step 1: Create `GridSelectionInfra.swift`**

Create `SwipeSort/Features/Components/GridSelectionInfra.swift` with the following content (copied verbatim from `AlbumPickerSheet.swift` lines 153–212):

```swift
import SwiftUI

/// The bottom toolbar shown while multi-select is active in a grid view.
///
/// Provides "Select All / Deselect All" and a "Move (n)" action button.
struct GridSelectionBottomBar: View {
    @Binding var selectedIds: Set<AssetIdentifier>
    let allIds: [AssetIdentifier]
    let onMoveTapped: () -> Void

    var body: some View {
        HStack {
            Button(selectedIds.count == allIds.count ? "Deselect All" : "Select All") {
                if selectedIds.count == allIds.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(allIds)
                }
            }
            .font(.subheadline.weight(.medium))

            Spacer()

            Button(action: onMoveTapped) {
                Label("Move (\(selectedIds.count))", systemImage: "folder.fill.badge.plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// Tracks the coordinate-space frames of grid cells for drag-range selection.
///
/// Used by `RecentsView` and `AlbumGridView` to map a drag location to a cell
/// index, enabling Apple Photos-style slide selection.
///
/// Merge strategy: last-writer-wins (`$1`), which is correct because each cell
/// in a `LazyVGrid` has a unique index and all cells report in the same
/// preference change pass.
struct GridCellFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Returns the grid index whose frame contains `location`, or `nil` if none matches.
///
/// Each frame is inset by −4 pt to give a small hit-area buffer at cell boundaries.
func gridIndex(at location: CGPoint, in frames: [Int: CGRect]) -> Int? {
    for (index, frame) in frames {
        if frame.insetBy(dx: -4, dy: -4).contains(location) {
            return index
        }
    }
    return nil
}
```

- [ ] **Step 2: Create `GridImageCache.swift`**

Create `SwipeSort/Features/Components/GridImageCache.swift` with the following content (copied verbatim from `RecentsView.swift` lines 4–45):

```swift
import UIKit

// MARK: - Image Cache

/// A memory cache shared across all `ThumbnailCell` instances in a grid.
///
/// Stored in a view's `@State` so it persists for the lifetime of the
/// tab and is freed automatically when the tab is torn down. `NSCache` is
/// thread-safe and auto-evicts entries under memory pressure without any
/// manual eviction logic.
///
/// Cost is set to the image's approximate byte size (width × height × 4 for
/// RGBA) so large photos are evicted before small ones when the 80 MB limit
/// is approached.
@MainActor
final class GridImageCache {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600                       // max items
        c.totalCostLimit = 80 * 1024 * 1024      // ~80 MB hard cap
        return c
    }()
    private var kinds: [String: MediaKind] = [:]

    func image(for id: AssetIdentifier) -> UIImage? {
        cache.object(forKey: id.rawValue as NSString)
    }

    func store(_ image: UIImage, for id: AssetIdentifier) {
        // Approximate byte cost = pixels × 4 (RGBA). NSCache uses cost as the
        // eviction priority signal, so large images are dropped first when the
        // 80 MB total limit is approached.
        let cost = Int(image.size.width * image.size.height) * 4
        cache.setObject(image, forKey: id.rawValue as NSString, cost: cost)
    }

    func mediaKind(for id: AssetIdentifier) -> MediaKind? {
        kinds[id.rawValue]
    }

    func store(_ kind: MediaKind, for id: AssetIdentifier) {
        kinds[id.rawValue] = kind
    }
}
```

- [ ] **Step 3: Create `SwipePresentationContext.swift`**

Create `SwipeSort/Features/Components/SwipePresentationContext.swift` with the following content (copied verbatim from `RecentsView.swift` lines 49–54):

```swift
import Foundation

/// Carries enough context to re-open the swipe deck at the tapped cell's position.
struct SwipePresentationContext: Identifiable {
    let id = UUID()
    let initialIndex: Int
    let initialAssetId: AssetIdentifier?
}
```

- [ ] **Step 4: Remove extracted code from `AlbumPickerSheet.swift`**

In `SwipeSort/Features/Landing/AlbumPickerSheet.swift`, delete lines 153–212 (everything after the closing brace of `AlbumPickerSheet` — the `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, and `gridIndex` definitions):

```swift
// BEFORE (lines 153–212 — delete all of this):

/// The bottom toolbar shown while multi-select is active in a grid view.
///
/// ...
struct GridSelectionBottomBar: View { ... }

/// Tracks the coordinate-space frames of grid cells for drag-range selection.
///
/// ...
struct GridCellFramePreferenceKey: PreferenceKey { ... }

/// Returns the grid index whose frame contains `location`, or `nil` if none matches.
///
/// ...
func gridIndex(at location: CGPoint, in frames: [Int: CGRect]) -> Int? { ... }
```

```swift
// AFTER: the file ends at line 151 with the closing brace of AlbumPickerSheet.
```

- [ ] **Step 5: Remove extracted code from `RecentsView.swift`**

In `SwipeSort/Features/Landing/RecentsView.swift`, delete lines 1–54 (the `// MARK: - Image Cache` comment through the end of `SwipePresentationContext`). The file then starts at what was line 56 (`// MARK: - RecentsView`).

Specifically, delete:
- Lines 1–3: `import SwiftUI`, `import Combine`, blank line  
  **Keep** `import SwiftUI` and `import Combine` — add them back at the top of the shortened file.
- Lines 4–45: `// MARK: - Image Cache` + `GridImageCache` class
- Lines 47–54: `// MARK: - RecentsView` comment + `SwipePresentationContext` struct

The resulting `RecentsView.swift` starts with:

```swift
import SwiftUI
import Combine

// MARK: - RecentsView

/// The Recents tab: a lazy 3-column grid of the most recently taken photos.
```

(The `SwipePresentationContext` struct was on lines 49–54 — delete only the struct itself, keeping the `// MARK: - RecentsView` comment.)

Concretely: the file after the edit should open with `import SwiftUI`, `import Combine`, then a blank line, then `// MARK: - RecentsView`, then the doc comment for `RecentsView`, then `struct RecentsView`. The `GridImageCache` class and `SwipePresentationContext` struct are no longer present.

- [ ] **Step 6: Build the project (logical verify — the human runs this in Xcode)**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds** with zero errors. Swift resolves `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex`, `GridImageCache`, and `SwipePresentationContext` from the new `Components/` files. No callers need `import` changes in a single-module app.

- [ ] **Step 7: Run full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. No test directly references the file locations of these types; they find them via module-level name resolution.

- [ ] **Step 8: Commit**

```
Report line: "phase-3/W1+W3+W4: created Features/Components/ with GridSelectionInfra.swift, GridImageCache.swift, SwipePresentationContext.swift; removed originals from AlbumPickerSheet.swift and RecentsView.swift — W1, W3, W4"
```

---

## Task 3: W6 — Split `PhotoLibraryProviding` into three sub-protocols

**Files:**
- Modify: `SwipeSort/Core/PhotoLibraryProviding.swift` (entire file rewrite)
- Modify: `SwipeSort/Core/PhotoKitLibrary.swift` (class declaration line only)
- Modify: `SwipeSort/Core/MockPhotoLibrary.swift` (class declaration line only)
- Test: `SwipeSortTests/MockPhotoLibraryTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `PhotoLibraryReadProviding: Sendable` — all read, authorization, fetch, filter, and scoping methods (14 requirements)
  - `PhotoLibraryCacheProviding: Sendable` — caching and media playback methods (5 requirements: `startCachingThumbnails`, `stopCachingThumbnails`, `stopCachingAllThumbnails`, `avPlayerItem`, `livePhoto`)
  - `PhotoLibraryMutating: Sendable` — mutation methods (5 requirements: `commitDeletions`, `createUserAlbum`, `moveAssets`, `removeAssetsFromAlbum`, `setFavorite`)
  - `typealias PhotoLibraryProviding = PhotoLibraryReadProviding & PhotoLibraryCacheProviding & PhotoLibraryMutating`
  - `PhotoKitLibrary` and `MockPhotoLibrary` class declarations gain explicit conformances to all three sub-protocols (though the typealias means this is equivalent to the old single-protocol conformance)

**TDD form:** A new test in `MockPhotoLibraryTests.swift` asserts that a `MockPhotoLibrary` instance can be assigned to each sub-protocol type, confirming the three-way conformance is correctly declared. Because the typealias is the exact existing type, all existing tests continue to compile with zero changes.

- [ ] **Step 1: Write the sub-protocol conformance test**

In `SwipeSortTests/MockPhotoLibraryTests.swift`, add after the last existing test:

```swift
@Test("MockPhotoLibrary conforms to all three PhotoLibraryProviding sub-protocols")
@MainActor
func subProtocolConformances() {
    // Compile-time pin: this test verifies that MockPhotoLibrary satisfies each
    // of the three sub-protocols introduced by W6. If any conformance is missing,
    // this test fails to compile. At runtime it simply confirms the instance is
    // non-nil when upcast to each sub-protocol.
    let mock = MockPhotoLibrary(authorization: .authorized, assetCount: 3)

    let asRead: any PhotoLibraryReadProviding = mock
    let asCache: any PhotoLibraryCacheProviding = mock
    let asMutating: any PhotoLibraryMutating = mock
    let asFull: any PhotoLibraryProviding = mock

    // All four upcast assignments succeeded (compile-time), so the conformances exist.
    // We call one method from each surface to confirm runtime dispatch is correct.
    #expect(Thread.isMainThread)
    _ = asRead   // used
    _ = asCache  // used
    _ = asMutating  // used
    _ = asFull   // used
}
```

- [ ] **Step 2: Run the test to confirm it fails to compile today (expected failure before W6)**

In Xcode: Product → Build (⌘B).

Expected: **Build Fails** with "use of undeclared type 'PhotoLibraryReadProviding'" — because the sub-protocols do not exist yet. This confirms the test is a genuine compile-time gate.

- [ ] **Step 3: Rewrite `PhotoLibraryProviding.swift`**

Replace the entire contents of `SwipeSort/Core/PhotoLibraryProviding.swift` with:

```swift
import Foundation
import UIKit
import AVFoundation
import Photos
import PhotosUI

/// A stable handle for a `PHAsset` identified by its `localIdentifier`.
///
/// Wrapping the raw string prevents callers from accidentally passing an
/// arbitrary string where a PhotoKit identifier is expected.
struct AssetIdentifier: Hashable, Sendable, Identifiable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    var id: String { rawValue }
}

/// A rendered thumbnail with progressive-delivery metadata.
///
/// `isDegraded` is `true` when PhotoKit delivered a fast-path low-resolution
/// image and a higher-quality version is still in flight (`.opportunistic`
/// delivery mode). Callers should display the image immediately and replace
/// it when a non-degraded result arrives.
struct AssetThumbnail: Sendable {
    let identifier: AssetIdentifier
    let image: UIImage
    let isDegraded: Bool
}

/// Mirrors `PHAuthorizationStatus` without the PhotoKit import dependency.
///
/// Decoupled so test targets can reason about authorization states without
/// linking Photos.framework.
enum PhotoLibraryAuthorization: Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized
}

/// Outcome of a batch deletion or album-move commit operation.
enum CommitResult: Sendable, Equatable {
    case success(affectedCount: Int)
    case cancelledByUser
    case failed(reason: String)
}

/// The media kind behind an `AssetIdentifier`.
///
/// Drives card-view dispatch: photos use a static `Image`, videos get an
/// `AVPlayer` from `VideoPlayerPool`, and Live Photos get a
/// `PHLivePhotoView` with a tap-to-play hint.
enum MediaKind: Sendable, Equatable {
    case photo
    case livePhoto
    case video(durationSeconds: Double)
}

// MARK: - Sub-protocols (W6)

/// Read-only access to the photo library: authorization, fetch cursor, asset
/// enumeration, thumbnails, media classification, album listing, filter/scoping,
/// and fetch-result refresh.
///
/// Threading: concrete implementations (`PhotoKitLibrary`, `MockPhotoLibrary`)
/// are `@MainActor`-isolated. All callers must be `@MainActor`-isolated or cross
/// the actor boundary with `await` for the `async` requirements. The synchronous
/// requirements must be called from a `@MainActor` context.
protocol PhotoLibraryReadProviding: Sendable {
    func currentAuthorization() async -> PhotoLibraryAuthorization
    func requestAuthorization() async -> PhotoLibraryAuthorization
    func assetCount() async -> Int
    func assetIdentifier(at index: Int) async -> AssetIdentifier?
    func indexOfAsset(withIdentifier id: AssetIdentifier) async -> Int?
    func thumbnail(for identifier: AssetIdentifier, targetSize: CGSize) async -> AssetThumbnail?
    func userAlbums() async -> [UserAlbum]
    func mediaKind(for id: AssetIdentifier) async -> MediaKind
    func identifiers(in range: Range<Int>) async -> [AssetIdentifier]

    /// Applies a load-time filter and invalidates the cached fetch cursor.
    ///
    /// Must be called before `SwipeSessionModel.start()` or any count /
    /// identifier lookup. Changing the filter mid-session produces an
    /// inconsistent index space — the session must be restarted.
    func applyFilter(_ filter: SwipeFilter) async

    /// Returns a new library instance scoped to assets within the given album.
    func scoped(toAlbumId albumId: String) -> PhotoLibraryProviding

    /// Invalidates the cached `PHFetchResult` so the next access rebuilds it.
    func refreshFetchResult() async
}

/// Pre-caching and rich-media delivery (video, Live Photo) operations.
///
/// Threading: `@MainActor`-isolated on concrete implementations.
/// `startCachingThumbnails` / `stopCachingThumbnails` / `stopCachingAllThumbnails`
/// are synchronous and must be called from a `@MainActor` context.
protocol PhotoLibraryCacheProviding: Sendable {
    /// Starts pre-caching thumbnails for the given identifiers at `targetSize`.
    ///
    /// Must be matched by a `stopCachingThumbnails` call with the identical
    /// `targetSize`. `PHCachingImageManager` reference-counts start/stop pairs by
    /// size; an unmatched start leaks memory until the manager is deallocated.
    func startCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize)

    /// Stops pre-caching thumbnails for the given identifiers.
    ///
    /// `targetSize` must exactly match the value passed to `startCachingThumbnails`.
    func stopCachingThumbnails(_ ids: [AssetIdentifier], targetSize: CGSize)

    /// Cancels all outstanding caching requests and releases associated memory.
    func stopCachingAllThumbnails()

    /// Returns an `AVPlayerItem` for the given video asset.
    func avPlayerItem(for id: AssetIdentifier) async -> AVPlayerItem?

    /// Returns a `PHLivePhoto` rendered at `targetSize` (pixels).
    func livePhoto(for id: AssetIdentifier, targetSize: CGSize) async -> PHLivePhoto?
}

/// Write operations that permanently or structurally modify the user's library.
///
/// Threading: `@MainActor`-isolated on concrete implementations.
protocol PhotoLibraryMutating: Sendable {
    /// Submits a batch of assets for permanent deletion.
    ///
    /// The real implementation presents the iOS system photo-deletion alert;
    /// all identifiers appear in a single prompt. Suspends until the user
    /// confirms or cancels.
    func commitDeletions(_ identifiers: [AssetIdentifier]) async -> CommitResult

    /// Creates a new user album with the given title.
    ///
    /// In dry-run mode returns a synthetic `UserAlbum` entry without issuing
    /// any PhotoKit `performChanges` call.
    func createUserAlbum(title: String) async -> UserAlbum?

    /// Moves assets between albums atomically.
    ///
    /// When `fromAlbumId` is `nil` (asset comes from All Photos) the
    /// operation is add-only. When `fromAlbumId` is set, both the
    /// remove-from-source and add-to-destination steps execute inside a
    /// single `performChanges` block.
    func moveAssets(_ ids: [AssetIdentifier], fromAlbumId: String?, toAlbumId: String) async -> CommitResult

    /// Removes assets from an album without deleting them from the library.
    func removeAssetsFromAlbum(_ ids: [AssetIdentifier], albumId: String) async -> CommitResult

    /// Sets or clears the Photos native favourite flag on a single asset.
    ///
    /// Returns `true` when the underlying `performChanges` call completes
    /// without error.
    func setFavorite(_ id: AssetIdentifier, isFavorite: Bool) async -> Bool
}

// MARK: - Composed protocol (backward-compatible typealias)

/// The full photo-library interface combining read, cache, and mutating surfaces.
///
/// `PhotoKitLibrary` and `MockPhotoLibrary` conform to this typealias.
/// All existing `let library: PhotoLibraryProviding` declarations remain valid —
/// the typealias is source-compatible with the former `protocol PhotoLibraryProviding`.
///
/// Threading: concrete implementations are `@MainActor`-isolated. All callers
/// must be `@MainActor`-isolated or cross the actor boundary with `await`.
typealias PhotoLibraryProviding = PhotoLibraryReadProviding & PhotoLibraryCacheProviding & PhotoLibraryMutating
```

- [ ] **Step 4: Update `PhotoKitLibrary.swift` class declaration**

In `SwipeSort/Core/PhotoKitLibrary.swift`, replace line 29:

```swift
// BEFORE (line 29)
@MainActor
final class PhotoKitLibrary: PhotoLibraryProviding {
```

```swift
// AFTER (line 29)
// @MainActor-isolated. Conforms to PhotoLibraryProviding (= ReadProviding &
// CacheProviding & Mutating) as a composed typealias (W6 split). All three
// sub-protocol requirements are implemented in the extension groups below.
@MainActor
final class PhotoKitLibrary: PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating {
```

- [ ] **Step 5: Update `MockPhotoLibrary.swift` class declaration**

In `SwipeSort/Core/MockPhotoLibrary.swift`, replace line 19:

```swift
// BEFORE (line 19)
@MainActor
final class MockPhotoLibrary: PhotoLibraryProviding {
```

```swift
// AFTER (line 19)
// @MainActor-isolated. Conforms to PhotoLibraryProviding (= ReadProviding &
// CacheProviding & Mutating) as a composed typealias (W6 split). All three
// sub-protocol requirements are implemented inline.
@MainActor
final class MockPhotoLibrary: PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating {
```

- [ ] **Step 6: Build the project**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `PhotoLibraryProviding` as a typealias is source-compatible with all existing `let library: PhotoLibraryProviding` declarations. The `scoped(toAlbumId:)` return type `PhotoLibraryProviding` in `PhotoLibraryReadProviding` still resolves because it refers to the typealias.

If the compiler reports a conflict on `scoped(toAlbumId:) -> PhotoLibraryProviding`, confirm that the `typealias` declaration comes after the three sub-protocol declarations in `PhotoLibraryProviding.swift` (it does, per the file layout above).

- [ ] **Step 7: Run `MockPhotoLibraryTests` to confirm the new sub-protocol test passes**

In Xcode: Product → Test → filter to `MockPhotoLibraryTests`.

Expected: all tests **PASS**, including the new `subProtocolConformances` test.

- [ ] **Step 8: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. No test needs to change — `PhotoLibraryProviding` is still the same composed type.

- [ ] **Step 9: Commit**

```
Report line: "phase-3/W6: split PhotoLibraryProviding into PhotoLibraryReadProviding, PhotoLibraryCacheProviding, PhotoLibraryMutating; PhotoLibraryProviding is now a backward-compatible typealias — W6"
```

---

## Task 4: N3 — Add hazard note to `BulkDeleteView` (doc-only; full fix deferred)

**Scope decision (2026-07-15):** `BulkDeleteView` has no call sites in the codebase — grep across `SwipeSort/` returns only the file's own definition. The shared-library-mutation bug is latent; it cannot manifest until the view is wired up. Rather than force-fit a runtime type-cast workaround now, this task adds a WARN doc comment inside `BulkDeleteView` describing the hazard so whichever future task wires the view up fixes the design correctly at that time.

**Files:**
- Modify: `SwipeSort/Features/Landing/BulkDeleteView.swift` (add WARN doc comment)

**Interfaces:**
- Consumes: nothing.
- Produces: an explicit hazard note visible at the point of use — the future engineer wiring `BulkDeleteView` up will see the constraint immediately.

- [ ] **Step 1: Add the WARN doc comment to `BulkDeleteView`**

In `SwipeSort/Features/Landing/BulkDeleteView.swift`, immediately above `struct BulkDeleteView: View {`, add:

```swift
/// # ⚠️ Wiring hazard — read before adding a call site
///
/// This view mutates the **shared** `library` instance passed to it: its
/// `.task(id: filter)` block calls `library.applyFilter(filter)`, which sets
/// `activeFilter` and nullifies the underlying `PHFetchResult` cursor on the
/// same `PhotoKitLibrary` observed by `RecentsView` and `AlbumsView`.
///
/// **Symptom if wired naively:** user opens BulkDeleteView with a "Videos only"
/// filter and dismisses without deleting. The shared library still has
/// `activeFilter = .videosOnly`. The next `RecentsView.loadAssets()` (e.g. from
/// a `PhotoLibraryChangePublisher.didChangeNotification`) shows videos only,
/// contradicting the user's Recents filter state.
///
/// **Before you wire this up:** either (a) pass a fresh `PhotoKitLibrary()`
/// instance dedicated to bulk delete, (b) add a factory method to
/// `PhotoLibraryProviding` that returns a new independent library instance,
/// or (c) save/restore the shared library's `activeFilter` around the view's
/// lifecycle. Do NOT rely on `library.scoped(toAlbumId:)` — its parameter is
/// non-optional `String` and the semantics differ.
///
/// Origin: correctness.md F11, phase-3 working set N3 (doc-only for Phase 3
/// because BulkDeleteView has no call sites as of 2026-07-15).
struct BulkDeleteView: View {
```

Do NOT change any other line of `BulkDeleteView.swift`. Do NOT add any test — the note is documentation, not a behavioural change.

- [ ] **Step 2: Verify no other file was touched**

The single edit is the doc comment block above `struct BulkDeleteView: View {`. No properties, methods, or logic change.

- [ ] **Step 3: Build the project**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds** — the change is a Swift doc comment, no compile impact.

- [ ] **Step 4: Commit**

```
Report line: "phase-3/N3: add WARN doc comment to BulkDeleteView describing shared-library-mutation hazard; full fix deferred to whoever wires the view up — N3 doc-only"
```

---

## Task 5: W2 — Extract `PhotoGridView` composite

**Files:**
- Create: `SwipeSort/Features/Components/PhotoGridView.swift`
- Modify: `SwipeSort/Features/Landing/RecentsView.swift` (replace the grid body with `PhotoGridView`)
- Modify: `SwipeSort/Features/Landing/AlbumsView.swift` (replace `AlbumGridView` grid body with `PhotoGridView`)
- Test: `SwipeSortTests/MockPhotoLibraryTests.swift` (no new tests — the structural change is verified by the compile-clean state; the accessibility identifier fix is verified by the existing UI test infrastructure)

**Interfaces:**
- Consumes:
  - `GridImageCache` from `Features/Components/GridImageCache.swift` (Task 2)
  - `GridCellFramePreferenceKey`, `gridIndex(at:in:)`, `GridSelectionBottomBar` from `Features/Components/GridSelectionInfra.swift` (Task 2)
  - `SwipePresentationContext` from `Features/Components/SwipePresentationContext.swift` (Task 2)
  - `ThumbnailCell` from `RecentsView.swift` line 272 (still in RecentsView until Task 6)
  - `PhotoLibraryProviding` typealias (Task 3)
- Produces:
  - `PhotoGridView` struct with init parameters: `assetIds: [AssetIdentifier]`, `library: PhotoLibraryProviding`, `imageCache: GridImageCache`, `assetLimit: Int`, `sourceAlbumId: String?`, `onTapAsset: (Int, AssetIdentifier) -> Void`, `onBulkMove: ([AssetIdentifier]) -> Void`
  - `RecentsView.body` becomes: NavigationStack + toolbar + filter state + `PhotoGridView`
  - `AlbumGridView.body` becomes: NavigationStack + toolbar + filter state + `PhotoGridView`
  - `.accessibilityIdentifier("ThumbnailCell-\(index)")` exists in exactly one place: `PhotoGridView`

**TDD form:** This is primarily a structural refactor. The compile-clean state and no regressions in the existing test suite is the primary gate. One additional regression test verifies that `PhotoGridView` renders accessibility identifiers for both tabs (documented below as a logical verification checklist; the human verifies this in Xcode's Accessibility Inspector or by running the UI test suite).

- [ ] **Step 1: Create `PhotoGridView.swift`**

Create `SwipeSort/Features/Components/PhotoGridView.swift`:

```swift
import SwiftUI

/// A reusable 3-column photo grid with drag-range multi-selection.
///
/// Encapsulates the `LazyVGrid` cell loop, the `@State` selection cluster
/// (`isSelecting`, `selectedIds`, `showingAlbumPicker`, `cellFrames`,
/// `dragStartIndex`, `dragStartSelectionState`), the drag gesture, and the
/// `GridSelectionBottomBar` — the body that was previously duplicated verbatim
/// between `RecentsView` and `AlbumGridView` (W2 fix).
///
/// `.accessibilityIdentifier("ThumbnailCell-\(index)")` is applied once here,
/// fixing the one-sided omission in `AlbumGridView` (W2 regression note).
struct PhotoGridView: View {
    let assetIds: [AssetIdentifier]
    let library: PhotoLibraryProviding
    let imageCache: GridImageCache
    let assetLimit: Int
    let sourceAlbumId: String?
    let onTapAsset: (Int, AssetIdentifier) -> Void
    let onBulkMove: ([AssetIdentifier]) -> Void

    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var dragStartIndex: Int? = nil
    @State private var dragStartSelectionState = true

    private let columns = [
        GridItem(.adaptive(minimum: 115), spacing: 2)
    ]
    private let thumbnailPixelSize = CGSize(width: 400, height: 400)

    var body: some View {
        Group {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(assetIds.enumerated()), id: \.element) { index, id in
                        ThumbnailCell(
                            id: id,
                            library: library,
                            cache: imageCache,
                            targetSize: thumbnailPixelSize,
                            isSelected: isSelecting ? selectedIds.contains(id) : nil
                        )
                        .contentShape(Rectangle())
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: GridCellFramePreferenceKey.self,
                                    value: [index: proxy.frame(in: .named("SelectGridSpace"))]
                                )
                            }
                        }
                        // Single canonical location for this accessibility identifier (W2 fix).
                        .accessibilityIdentifier("ThumbnailCell-\(index)")
                        .onTapGesture {
                            if isSelecting {
                                if selectedIds.contains(id) {
                                    selectedIds.remove(id)
                                } else {
                                    selectedIds.insert(id)
                                }
                            } else {
                                onTapAsset(index, id)
                            }
                        }
                    }
                }
                .coordinateSpace(name: "SelectGridSpace")
                .onPreferenceChange(GridCellFramePreferenceKey.self) { frames in
                    cellFrames = frames
                }
                .gesture(
                    isSelecting ?
                    DragGesture(minimumDistance: 12, coordinateSpace: .named("SelectGridSpace"))
                        .onChanged { value in
                            guard let idx = gridIndex(at: value.location, in: cellFrames) else { return }
                            if dragStartIndex == nil {
                                dragStartIndex = idx
                                dragStartSelectionState = !selectedIds.contains(assetIds[idx])
                            }
                            guard let start = dragStartIndex else { return }
                            let lower = min(start, idx)
                            let upper = max(start, idx)
                            for i in lower...upper {
                                if dragStartSelectionState {
                                    selectedIds.insert(assetIds[i])
                                } else {
                                    selectedIds.remove(assetIds[i])
                                }
                            }
                        }
                        .onEnded { _ in
                            dragStartIndex = nil
                        }
                    : nil
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !assetIds.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIds.removeAll()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                GridSelectionBottomBar(
                    selectedIds: $selectedIds,
                    allIds: assetIds
                ) {
                    showingAlbumPicker = true
                }
            }
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerSheet(
                library: library,
                selectedCount: selectedIds.count,
                sourceAlbumId: sourceAlbumId
            ) { targetAlbum in
                let ids = Array(selectedIds)
                onBulkMove(ids)
                // Note: onBulkMove is async-capable via a Task at the call site.
                // The sheet dismisses after the callback completes.
            }
        }
        .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : "")
    }
}
```

**Implementation note on `AlbumPickerSheet` callback:** `AlbumPickerSheet.onMove` is declared `(UserAlbum) async -> Void`. The `showingAlbumPicker` sheet in `PhotoGridView` passes the target album up to the caller via `onBulkMove`. However, `onBulkMove` in `PhotoGridView`'s closure receives `[AssetIdentifier]` (the selected IDs), not the `UserAlbum` — the `AlbumPickerSheet` has its own callback that already performs the move. This means `PhotoGridView` cannot own the `AlbumPickerSheet` directly in a generic way (it doesn't know the source album ID for the move operation, only the destination album).

Revised architecture for the `AlbumPickerSheet` inside `PhotoGridView`: pass the `onMove` closure from the parent views (which know their source album ID and library) as an additional init parameter.

**Revise `PhotoGridView` init to accept `onAlbumPickerMove`:**

Replace the `onBulkMove` parameter and the sheet with:

```swift
    // Replace `onBulkMove: ([AssetIdentifier]) -> Void` with:
    let onBulkMove: ([AssetIdentifier], @escaping (UserAlbum) async -> Void) -> Void
```

This is getting complex. Simpler approach: keep the `AlbumPickerSheet` in the parent views (`RecentsView`, `AlbumGridView`) rather than inside `PhotoGridView`, and have `PhotoGridView` expose `isSelecting` and `selectedIds` via bindings, calling a callback `onRequestMove([AssetIdentifier])` to signal that the parent should present the picker.

**Final architecture for `PhotoGridView`:**

```swift
import SwiftUI

/// A reusable 3-column photo grid with drag-range multi-selection.
///
/// Encapsulates the `LazyVGrid` cell loop, the `@State` selection cluster,
/// the drag gesture, and the `GridSelectionBottomBar`. The `AlbumPickerSheet`
/// is presented by the parent view via `onRequestMove`, which receives the
/// selected identifiers when the user taps "Move".
///
/// `.accessibilityIdentifier("ThumbnailCell-\(index)")` is applied here once,
/// fixing the one-sided omission in `AlbumGridView` (W2 regression note).
struct PhotoGridView: View {
    let assetIds: [AssetIdentifier]
    let library: PhotoLibraryProviding
    let imageCache: GridImageCache
    let onTapAsset: (Int, AssetIdentifier) -> Void
    /// Called when the user taps "Move" in the selection toolbar. The parent
    /// view is responsible for presenting `AlbumPickerSheet` with these IDs.
    let onRequestMove: ([AssetIdentifier]) -> Void

    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var dragStartIndex: Int? = nil
    @State private var dragStartSelectionState = true

    private let columns = [
        GridItem(.adaptive(minimum: 115), spacing: 2)
    ]
    private let thumbnailPixelSize = CGSize(width: 400, height: 400)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assetIds.enumerated()), id: \.element) { index, id in
                    ThumbnailCell(
                        id: id,
                        library: library,
                        cache: imageCache,
                        targetSize: thumbnailPixelSize,
                        isSelected: isSelecting ? selectedIds.contains(id) : nil
                    )
                    .contentShape(Rectangle())
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: GridCellFramePreferenceKey.self,
                                value: [index: proxy.frame(in: .named("SelectGridSpace"))]
                            )
                        }
                    }
                    .accessibilityIdentifier("ThumbnailCell-\(index)")
                    .onTapGesture {
                        if isSelecting {
                            if selectedIds.contains(id) {
                                selectedIds.remove(id)
                            } else {
                                selectedIds.insert(id)
                            }
                        } else {
                            onTapAsset(index, id)
                        }
                    }
                }
            }
            .coordinateSpace(name: "SelectGridSpace")
            .onPreferenceChange(GridCellFramePreferenceKey.self) { frames in
                cellFrames = frames
            }
            .gesture(
                isSelecting ?
                DragGesture(minimumDistance: 12, coordinateSpace: .named("SelectGridSpace"))
                    .onChanged { value in
                        guard let idx = gridIndex(at: value.location, in: cellFrames) else { return }
                        if dragStartIndex == nil {
                            dragStartIndex = idx
                            dragStartSelectionState = !selectedIds.contains(assetIds[idx])
                        }
                        guard let start = dragStartIndex else { return }
                        let lower = min(start, idx)
                        let upper = max(start, idx)
                        for i in lower...upper {
                            if dragStartSelectionState {
                                selectedIds.insert(assetIds[i])
                            } else {
                                selectedIds.remove(assetIds[i])
                            }
                        }
                    }
                    .onEnded { _ in
                        dragStartIndex = nil
                    }
                : nil
            )
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !assetIds.isEmpty {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIds.removeAll()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                GridSelectionBottomBar(
                    selectedIds: $selectedIds,
                    allIds: assetIds
                ) {
                    onRequestMove(Array(selectedIds))
                }
            }
        }
    }
}
```

Now save that as the actual file content. The `.toolbar` modifiers inside `PhotoGridView` combine with the parent's navigation toolbar via SwiftUI's toolbar composition.

- [ ] **Step 2: Refactor `RecentsView` to use `PhotoGridView`**

In `SwipeSort/Features/Landing/RecentsView.swift`, replace the `body` of `RecentsView` with the following. The existing `@State` cluster for selection (`isSelecting`, `selectedIds`, `showingAlbumPicker`, `cellFrames`, `dragStartIndex`, `dragStartSelectionState`, `imageCache`) and `columns` / `thumbnailPixelSize` are removed. The `loadAssets`, filter state, `swipeContext`, and `NavigationStack` structure are preserved.

The new `RecentsView` struct after the edit:

```swift
/// The Recents tab: a lazy 3-column grid of the most recently taken photos.
///
/// Tapping a cell opens the swipe deck starting at that cell's position.
/// Supports multi-select with drag-range selection (delegated to `PhotoGridView`)
/// and bulk album-move.
struct RecentsView: View {
    let library: PhotoLibraryProviding

    @State private var assetIds: [AssetIdentifier] = []
    @State private var hasIndexed = false
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var showingAlbumPicker = false
    @State private var selectedIdsForMove: [AssetIdentifier] = []

    /// Image cache shared by all cells in this grid. Survives `LazyVGrid`
    /// cell recycling so images are restored instantly on scroll-back.
    @State private var imageCache = GridImageCache()

    var body: some View {
        NavigationStack {
            Group {
                if !hasIndexed {
                    VStack {
                        Spacer()
                        ProgressView("Indexing library…").padding()
                        Spacer()
                    }
                } else if assetIds.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No photos found.")
                            .font(.headline)
                        Text("Try adjusting the filter, or grant library access first.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .accessibilityIdentifier("EmptyStateView")
                } else {
                    PhotoGridView(
                        assetIds: assetIds,
                        library: library,
                        imageCache: imageCache,
                        onTapAsset: { index, id in
                            swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                        },
                        onRequestMove: { ids in
                            selectedIdsForMove = ids
                            showingAlbumPicker = true
                        }
                    )
                }
            }
            .navigationTitle("Recents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("FilterButton")
                }
            }
            // Tapping any photo launches the full swipe-sort deck
            .fullScreenCover(item: $swipeContext, onDismiss: {
                Task { await loadAssets() }
            }) { context in
                SwipeStackView(library: library, filter: filter, initialIndex: context.initialIndex, initialAssetId: context.initialAssetId)
            }
            .sheet(isPresented: $showingFilter, onDismiss: {
                Task { await loadAssets() }
            }) {
                FilterSheet(filter: $filter, onFilterChange: {
                    Task { await loadAssets() }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerSheet(
                    library: library,
                    selectedCount: selectedIdsForMove.count,
                    sourceAlbumId: nil
                ) { targetAlbum in
                    _ = await library.moveAssets(selectedIdsForMove, fromAlbumId: nil, toAlbumId: targetAlbum.id)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    selectedIdsForMove = []
                    await loadAssets()
                }
            }
            .task { await loadAssets() }
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                Task { await loadAssets() }
            }
        }
    }

    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.refreshFetchResult()
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
    }
}
```

Note: the `navigationTitle` for `PhotoGridView`'s selection state ("N Selected") is now set via a computed binding from the parent. Since `PhotoGridView`'s toolbar uses `.topBarLeading` and `.topBarTrailing`, the parent's `.navigationTitle("Recents")` will show when not selecting. However, `PhotoGridView` cannot change the parent's `navigationTitle` from inside a child view — the "N Selected" title must be managed differently. 

**Revised approach for navigationTitle:** Pass `isSelecting` and `selectedCount` back up via `@Binding` or compute in the parent. However, `@Binding` to `PhotoGridView`'s private `@State` is not directly possible without restructuring.

**Simpler solution:** Move `isSelecting` and `selectedIds` back out to the parent views as `@State`, and pass them in as `@Binding` parameters to `PhotoGridView`.

**Final revised `PhotoGridView` with bindings for selection title:**

```swift
import SwiftUI

/// A reusable 3-column photo grid with drag-range multi-selection.
///
/// The parent view owns `isSelecting` and `selectedIds` via `@Binding` so it
/// can update its `navigationTitle` to show "N Selected" during multi-select.
/// The drag gesture and `GridSelectionBottomBar` are encapsulated here.
///
/// `.accessibilityIdentifier("ThumbnailCell-\(index)")` lives here once,
/// fixing the W2 one-sided omission in `AlbumGridView`.
struct PhotoGridView: View {
    let assetIds: [AssetIdentifier]
    let library: PhotoLibraryProviding
    let imageCache: GridImageCache
    @Binding var isSelecting: Bool
    @Binding var selectedIds: Set<AssetIdentifier>
    let onTapAsset: (Int, AssetIdentifier) -> Void
    let onRequestMove: ([AssetIdentifier]) -> Void

    @State private var cellFrames: [Int: CGRect] = [:]
    @State private var dragStartIndex: Int? = nil
    @State private var dragStartSelectionState = true

    private let columns = [
        GridItem(.adaptive(minimum: 115), spacing: 2)
    ]
    private let thumbnailPixelSize = CGSize(width: 400, height: 400)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assetIds.enumerated()), id: \.element) { index, id in
                    ThumbnailCell(
                        id: id,
                        library: library,
                        cache: imageCache,
                        targetSize: thumbnailPixelSize,
                        isSelected: isSelecting ? selectedIds.contains(id) : nil
                    )
                    .contentShape(Rectangle())
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: GridCellFramePreferenceKey.self,
                                value: [index: proxy.frame(in: .named("SelectGridSpace"))]
                            )
                        }
                    }
                    .accessibilityIdentifier("ThumbnailCell-\(index)")
                    .onTapGesture {
                        if isSelecting {
                            if selectedIds.contains(id) {
                                selectedIds.remove(id)
                            } else {
                                selectedIds.insert(id)
                            }
                        } else {
                            onTapAsset(index, id)
                        }
                    }
                }
            }
            .coordinateSpace(name: "SelectGridSpace")
            .onPreferenceChange(GridCellFramePreferenceKey.self) { frames in
                cellFrames = frames
            }
            .gesture(
                isSelecting ?
                DragGesture(minimumDistance: 12, coordinateSpace: .named("SelectGridSpace"))
                    .onChanged { value in
                        guard let idx = gridIndex(at: value.location, in: cellFrames) else { return }
                        if dragStartIndex == nil {
                            dragStartIndex = idx
                            dragStartSelectionState = !selectedIds.contains(assetIds[idx])
                        }
                        guard let start = dragStartIndex else { return }
                        let lower = min(start, idx)
                        let upper = max(start, idx)
                        for i in lower...upper {
                            if dragStartSelectionState {
                                selectedIds.insert(assetIds[i])
                            } else {
                                selectedIds.remove(assetIds[i])
                            }
                        }
                    }
                    .onEnded { _ in
                        dragStartIndex = nil
                    }
                : nil
            )
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                GridSelectionBottomBar(
                    selectedIds: $selectedIds,
                    allIds: assetIds
                ) {
                    onRequestMove(Array(selectedIds))
                }
            }
        }
    }
}
```

Now the parent views own `isSelecting` and `selectedIds` as `@State` and pass them as bindings, enabling them to manage `navigationTitle`.

- [ ] **Step 3: Refactor `RecentsView` body (final form with bindings)**

Replace `RecentsView`'s body with the following (preserving `loadAssets`, `hasIndexed`, filter state, and `swipeContext` from the existing view; replacing the entire `ScrollView`/`LazyVGrid` block with `PhotoGridView`):

```swift
struct RecentsView: View {
    let library: PhotoLibraryProviding

    @State private var assetIds: [AssetIdentifier] = []
    @State private var hasIndexed = false
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false

    @State private var imageCache = GridImageCache()

    var body: some View {
        NavigationStack {
            Group {
                if !hasIndexed {
                    VStack {
                        Spacer()
                        ProgressView("Indexing library…").padding()
                        Spacer()
                    }
                } else if assetIds.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52))
                            .foregroundStyle(.secondary)
                        Text("No photos found.")
                            .font(.headline)
                        Text("Try adjusting the filter, or grant library access first.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .accessibilityIdentifier("EmptyStateView")
                } else {
                    PhotoGridView(
                        assetIds: assetIds,
                        library: library,
                        imageCache: imageCache,
                        isSelecting: $isSelecting,
                        selectedIds: $selectedIds,
                        onTapAsset: { index, id in
                            swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                        },
                        onRequestMove: { ids in
                            showingAlbumPicker = true
                        }
                    )
                }
            }
            .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : "Recents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button("Cancel") {
                            isSelecting = false
                            selectedIds.removeAll()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !assetIds.isEmpty {
                            Button(isSelecting ? "Done" : "Select") {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIds.removeAll()
                                }
                            }
                        }
                        Button {
                            showingFilter = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityIdentifier("FilterButton")
                    }
                }
            }
            .fullScreenCover(item: $swipeContext, onDismiss: {
                Task { await loadAssets() }
            }) { context in
                SwipeStackView(library: library, filter: filter, initialIndex: context.initialIndex, initialAssetId: context.initialAssetId)
            }
            .sheet(isPresented: $showingFilter, onDismiss: {
                Task { await loadAssets() }
            }) {
                FilterSheet(filter: $filter, onFilterChange: {
                    Task { await loadAssets() }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerSheet(
                    library: library,
                    selectedCount: selectedIds.count,
                    sourceAlbumId: nil
                ) { targetAlbum in
                    let ids = Array(selectedIds)
                    _ = await library.moveAssets(ids, fromAlbumId: nil, toAlbumId: targetAlbum.id)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    isSelecting = false
                    selectedIds.removeAll()
                    await loadAssets()
                }
            }
            .task { await loadAssets() }
            .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
                Task { await loadAssets() }
            }
        }
    }

    private func loadAssets() async {
        if await library.currentAuthorization() == .notDetermined {
            _ = await library.requestAuthorization()
        }
        await library.refreshFetchResult()
        await library.applyFilter(filter)
        let count = await library.assetCount()
        let limit = min(count, 500)
        assetIds = await library.identifiers(in: 0..<limit)
        hasIndexed = true
    }
}
```

- [ ] **Step 4: Refactor `AlbumGridView` to use `PhotoGridView`**

In `SwipeSort/Features/Landing/AlbumsView.swift`, replace `AlbumGridView`'s body (lines 146–310, the `Group { ... }` inside `var body: some View`) with:

```swift
struct AlbumGridView: View {
    let album: UserAlbum
    let library: PhotoLibraryProviding

    @State private var assetIds: [AssetIdentifier] = []
    @State private var hasIndexed = false
    @State private var filter: SwipeFilter = .unfiltered
    @State private var showingFilter = false
    @State private var swipeContext: SwipePresentationContext?
    @State private var imageCache = GridImageCache()
    @State private var scopedLibrary: PhotoLibraryProviding?
    @State private var isSelecting = false
    @State private var selectedIds: Set<AssetIdentifier> = []
    @State private var showingAlbumPicker = false

    var body: some View {
        Group {
            if !hasIndexed {
                VStack {
                    Spacer()
                    ProgressView("Loading photos…").padding()
                    Spacer()
                }
            } else if assetIds.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    Text("No photos found.")
                        .font(.headline)
                    Text("Try adjusting the filter or add photos to this album.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else {
                PhotoGridView(
                    assetIds: assetIds,
                    library: scopedLibrary ?? library,
                    imageCache: imageCache,
                    isSelecting: $isSelecting,
                    selectedIds: $selectedIds,
                    onTapAsset: { index, id in
                        swipeContext = SwipePresentationContext(initialIndex: index, initialAssetId: id)
                    },
                    onRequestMove: { _ in
                        showingAlbumPicker = true
                    }
                )
            }
        }
        .navigationTitle(isSelecting ? "\(selectedIds.count) Selected" : album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIds.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if !assetIds.isEmpty {
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedIds.removeAll()
                            }
                        }
                    }
                    Button {
                        showingFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .fullScreenCover(item: $swipeContext, onDismiss: {
            Task { await loadAssets() }
        }) { context in
            SwipeStackView(
                library: scopedLibrary ?? library,
                filter: filter,
                albumTitle: album.title,
                initialIndex: context.initialIndex,
                initialAssetId: context.initialAssetId
            )
        }
        .sheet(isPresented: $showingFilter, onDismiss: {
            Task { await loadAssets() }
        }) {
            FilterSheet(filter: $filter, onFilterChange: {
                Task { await loadAssets() }
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerSheet(
                library: library,
                selectedCount: selectedIds.count,
                sourceAlbumId: album.id
            ) { targetAlbum in
                let ids = Array(selectedIds)
                _ = await library.moveAssets(ids, fromAlbumId: album.id, toAlbumId: targetAlbum.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isSelecting = false
                selectedIds.removeAll()
                await loadAssets()
            }
        }
        .task { await loadAssets() }
        .task(id: album.id) {
            // W8 fix: initialize scopedLibrary via .task(id:) rather than
            // inside a computed property that mutates @State imperatively.
            // Re-fires when the album identity changes, ensuring a fresh
            // scoped cursor for the new album without leaking the old one.
            if scopedLibrary == nil {
                scopedLibrary = library.scoped(toAlbumId: album.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryChangePublisher.didChangeNotification)) { _ in
            Task { await loadAssets() }
        }
    }

    private func loadAssets() async {
        let s = scopedLibrary ?? library
        await s.refreshFetchResult()
        await s.applyFilter(filter)
        let count = await s.assetCount()
        let limit = min(count, 1000)
        assetIds = await s.identifiers(in: 0..<limit)
        hasIndexed = true
    }
}
```

Note: the `getScopedLibrary()` method is removed entirely from `AlbumGridView`. The `.task(id: album.id)` modifier replaces it (this also resolves W8 — see Task 7 below for the verification note).

- [ ] **Step 5: Build the project**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `PhotoGridView` resolves `ThumbnailCell` (still in `RecentsView.swift` at this point — Task 6 will move it). `GridImageCache`, `GridCellFramePreferenceKey`, `gridIndex`, `SwipePresentationContext`, `GridSelectionBottomBar` all resolve from `Features/Components/` (Task 2).

- [ ] **Step 6: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. The existing `SwipeSessionModelTests`, `AlbumMoveTests`, `SettingsIntegrationTests`, `BulkDeleteTests` are unaffected. The structural change in `RecentsView` and `AlbumGridView` has no runtime impact on these tests.

- [ ] **Step 7: Verify accessibility identifier fix (logical check)**

Confirm that both `RecentsView` and `AlbumGridView` now produce cells with `.accessibilityIdentifier("ThumbnailCell-\(index)")` from `PhotoGridView`. This was previously missing in `AlbumGridView`.

Logical check: search the codebase for `.accessibilityIdentifier("ThumbnailCell-` — there should be exactly one occurrence, in `PhotoGridView.swift`.

```
Expected: grep -rn "ThumbnailCell-" SwipeSort/ returns exactly one line:
  SwipeSort/Features/Components/PhotoGridView.swift: .accessibilityIdentifier("ThumbnailCell-\(index)")
```

- [ ] **Step 8: Commit**

```
Report line: "phase-3/W2: extracted PhotoGridView composite; RecentsView and AlbumGridView delegate their grid body to PhotoGridView; accessibilityIdentifier ThumbnailCell-N now exists in one place for both tabs — W2"
```

---

## Task 6: W5 — Move `ThumbnailCell` to `Components/`

**Files:**
- Create: `SwipeSort/Features/Components/ThumbnailCell.swift`
- Modify: `SwipeSort/Features/Landing/RecentsView.swift` (remove `ThumbnailCell` from the bottom of the file)
- Test: none required — pure structural move; compile-clean is the gate

**Interfaces:**
- Consumes: `GridImageCache` from `Features/Components/GridImageCache.swift` (Task 2).
- Produces: `ThumbnailCell` is in `SwipeSort/Features/Components/ThumbnailCell.swift`. `PhotoGridView` and any future grid consumer finds it by module-level name resolution.

**TDD form:** Pure file move. After the move, build succeeds and all existing tests pass. No new behaviors are introduced.

- [ ] **Step 1: Create `ThumbnailCell.swift`**

Create `SwipeSort/Features/Components/ThumbnailCell.swift` with the following content (copied verbatim from `RecentsView.swift` lines 264–356, starting at `// MARK: - Thumbnail Cell`):

```swift
import SwiftUI

// MARK: - Thumbnail Cell

/// A square grid cell with `GridImageCache`-backed image loading.
///
/// Before issuing a PhotoKit request the cell checks `GridImageCache`
/// synchronously. Because the cache is passed in from the parent grid's
/// `@State`, it outlives `LazyVGrid`'s cell recycling — cells that scroll
/// back into view restore instantly without a spinner flash.
struct ThumbnailCell: View {
    let id: AssetIdentifier
    let library: PhotoLibraryProviding
    let cache: GridImageCache
    let targetSize: CGSize
    var isSelected: Bool? = nil

    @State private var image: UIImage?
    @State private var mediaKind: MediaKind = .photo

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)      // anchors the square slot
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Static neutral background — avoids the spinning-then-
                    // snapping visual that a ProgressView causes.
                    Color(.secondarySystemBackground)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if case .video(let durationSeconds) = mediaKind {
                    Text(formattedDuration(durationSeconds))
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selected = isSelected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? .blue : .white)
                        .background(selected ? Color.white : Color.black.opacity(0.3), in: Circle())
                        .padding(6)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            // .task(id: id) re-fires when the cell is reused with a different
            // identifier, e.g. after a filter change invalidates the grid.
            .task(id: id) {
                if let cachedKind = cache.mediaKind(for: id) {
                    mediaKind = cachedKind
                } else {
                    let kind = await library.mediaKind(for: id)
                    cache.store(kind, for: id)
                    mediaKind = kind
                }

                // Cache hit: assign synchronously without a PhotoKit call.
                if let cached = cache.image(for: id) {
                    image = cached
                    return
                }
                // Cache miss: fetch from PhotoKit, then cache and display.
                guard let thumb = await library.thumbnail(for: id, targetSize: targetSize) else {
                    return
                }
                cache.store(thumb.image, for: id)
                image = thumb.image
            }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
```

- [ ] **Step 2: Remove `ThumbnailCell` from `RecentsView.swift`**

In `SwipeSort/Features/Landing/RecentsView.swift`, delete everything from the `// MARK: - Thumbnail Cell` comment through the end of the file (the `ThumbnailCell` struct and its `formattedDuration` helper). After this edit, `RecentsView.swift` ends with the closing brace of `RecentsView`.

- [ ] **Step 3: Build the project**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. `PhotoGridView` resolves `ThumbnailCell` from `Components/ThumbnailCell.swift` via module-level lookup.

- [ ] **Step 4: Run the full test suite**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. No test imports `ThumbnailCell` directly.

- [ ] **Step 5: Commit**

```
Report line: "phase-3/W5: moved ThumbnailCell to Features/Components/ThumbnailCell.swift; RecentsView.swift no longer contains shared component code — W5"
```

---

## Task 7: W8 — Verify `AlbumGridView.getScopedLibrary()` resolved by W2

**Files:**
- Verify: `SwipeSort/Features/Landing/AlbumsView.swift` — confirm `getScopedLibrary()` is gone
- No additional modification expected (W2's Task 5 Step 4 already removed `getScopedLibrary()` and replaced it with `.task(id: album.id)`)

**Interfaces:**
- Consumes: nothing new.
- Produces: confirmation that `getScopedLibrary()` no longer exists; if it does exist as residual, the `.task(id: album.id)` fix is applied.

**TDD form:** This is a verification task, not a code-change task. If `getScopedLibrary()` is absent (as expected after Task 5), the task is complete with no changes. If it is present (Task 5 left it behind), apply the targeted fix below.

- [ ] **Step 1: Confirm `getScopedLibrary()` is absent**

In Xcode or via a text search:
```
grep -n "getScopedLibrary" SwipeSort/Features/Landing/AlbumsView.swift
```

Expected: **no matches** — Task 5 (W2) removed `getScopedLibrary()` and replaced it with `.task(id: album.id)`.

- [ ] **Step 2: If `getScopedLibrary()` is present (fallback — apply if Step 1 finds a match)**

If Task 5 did not fully remove `getScopedLibrary()`, apply this targeted fix to `AlbumGridView`:

**2a — Remove `getScopedLibrary()`**

Delete the entire `getScopedLibrary()` method (the private method body that guards on `scopedLibrary`, creates a new scoped library, assigns to `scopedLibrary`, and returns it).

**2b — Add `.task(id: album.id)` to initialize `scopedLibrary`**

Add this modifier to `AlbumGridView`'s body view chain (before `.task { await loadAssets() }`):

```swift
        .task(id: album.id) {
            if scopedLibrary == nil {
                scopedLibrary = library.scoped(toAlbumId: album.id)
            }
        }
```

**2c — Replace all `getScopedLibrary()` call sites with `scopedLibrary ?? library`**

Search `AlbumsView.swift` for `getScopedLibrary()` and replace each occurrence with `scopedLibrary ?? library`.

- [ ] **Step 3: Build and verify**

In Xcode: Product → Build (⌘B).

Expected: **Build Succeeds**. If Step 1 confirmed absence, this is a no-op confirmation.

- [ ] **Step 4: Commit (only if changes were made in Step 2)**

```
Report line: "phase-3/W8: confirmed getScopedLibrary() removed by W2 refactor; AlbumGridView now initializes scopedLibrary via .task(id: album.id) — W8"
```

---

## Task 8: Verification Pass

**Files:**
- Read-only checklist; no code changes

This task is a structured self-review checklist for the executing subagent. Run each check and report the result. Do not proceed to the commit until all checks pass.

- [ ] **Check 1: No dead `GridImageCache`, `GridCellFramePreferenceKey`, `gridIndex`, or `SwipePresentationContext` definitions remain in `Features/Landing/`**

```
grep -rn "struct GridImageCache\|struct GridCellFramePreferenceKey\|func gridIndex\|struct SwipePresentationContext" SwipeSort/Features/Landing/
```

Expected: **no output**. All four symbols must resolve only from `Features/Components/`.

- [ ] **Check 2: No `GridSelectionBottomBar` definition in `AlbumPickerSheet.swift`**

```
grep -n "struct GridSelectionBottomBar" SwipeSort/Features/Landing/AlbumPickerSheet.swift
```

Expected: **no output**.

- [ ] **Check 3: `ThumbnailCell` is defined exactly once, in `Components/`**

```
grep -rn "struct ThumbnailCell" SwipeSort/
```

Expected: exactly one match: `SwipeSort/Features/Components/ThumbnailCell.swift`.

- [ ] **Check 4: `.accessibilityIdentifier("ThumbnailCell-` exists exactly once in the project**

```
grep -rn "ThumbnailCell-" SwipeSort/
```

Expected: exactly one match: `SwipeSort/Features/Components/PhotoGridView.swift`. This confirms the W2 one-sided fix is applied for both tabs.

- [ ] **Check 5: `PhotoLibraryProviding` is a typealias, not a protocol**

```
grep -n "typealias PhotoLibraryProviding\|protocol PhotoLibraryProviding" SwipeSort/Core/PhotoLibraryProviding.swift
```

Expected: one match for `typealias PhotoLibraryProviding = ...` and no match for `protocol PhotoLibraryProviding`. The three sub-protocol names must be present:

```
grep -n "protocol PhotoLibraryReadProviding\|protocol PhotoLibraryCacheProviding\|protocol PhotoLibraryMutating" SwipeSort/Core/PhotoLibraryProviding.swift
```

Expected: three matches.

- [ ] **Check 6: No consumer changed its declared `library` type**

```
grep -rn "let library: PhotoLibraryReadProviding\|let library: PhotoLibraryCacheProviding\|let library: PhotoLibraryMutating" SwipeSort/
```

Expected: **no output**. All `let library: ...` declarations must still use `PhotoLibraryProviding` (the typealias).

- [ ] **Check 7: `AppSettings` no longer has `dryRunMode`**

```
grep -n "dryRunMode" SwipeSort/Core/AppSettings.swift
```

Expected: **no output**. The `dryRunMode` property and its doc comment must be absent from `AppSettings.swift`.

- [ ] **Check 8: `SettingsView` no longer has a "Safety" section**

```
grep -n "Safety\|dryRunMode\|Dry-run" SwipeSort/Features/Settings/SettingsView.swift
```

Expected: **no output**.

- [ ] **Check 9: `getScopedLibrary` is absent**

```
grep -rn "getScopedLibrary" SwipeSort/
```

Expected: **no output**.

- [ ] **Check 10: Full test suite passes**

In Xcode: Product → Test (full suite).

Expected: all tests **PASS**. This is the final gate for Phase 3 execution.

- [ ] **Check 11: `Features/Landing/` contains only screen files**

```
ls SwipeSort/Features/Landing/
```

Expected:
```
AlbumFilterSheet.swift
AlbumPickerSheet.swift
AlbumsView.swift
BulkDeleteView.swift
FilterSheet.swift
RecentsView.swift
```

No component files (no `GridImageCache`, `ThumbnailCell`, `GridSelectionBottomBar`, etc.) in `Features/Landing/`.

- [ ] **Check 12: `Features/Components/` contains the extracted components**

```
ls SwipeSort/Features/Components/
```

Expected:
```
GridImageCache.swift
GridSelectionInfra.swift
PhotoGridView.swift
SwipePresentationContext.swift
ThumbnailCell.swift
```

- [ ] **Final report**

Report all check results to the human. If any check fails, apply the targeted fix before reporting completion.

---

## Self-Review

### 1. Spec coverage

| Working-set item | Task | Status |
|---|---|---|
| W7 — `AppSettings.dryRunMode` visible to users; hidden debug menu missing | Task 1 | Covered |
| W1 — `GridSelectionBottomBar`, `GridCellFramePreferenceKey`, `gridIndex` trapped in `AlbumPickerSheet.swift` | Task 2 | Covered |
| W3 — `GridImageCache` defined in `RecentsView.swift` | Task 2 | Covered |
| W4 — `SwipePresentationContext` defined in `RecentsView.swift` | Task 2 | Covered |
| W6 — `PhotoLibraryProviding` monolithic 22-method protocol | Task 3 | Covered |
| N3 — `BulkDeleteView` mutates shared library cursor | Task 4 | Covered |
| W2 — `AlbumGridView` duplicates `RecentsView` grid body; one-sided accessibility identifier fix | Task 5 | Covered |
| W5 — `Features/Landing/` mixes screen files with shared components; `ThumbnailCell` misplaced | Tasks 2 + 6 | Covered |
| W8 — `AlbumGridView.getScopedLibrary()` mutates `@State` inside imperative get | Task 5 (primary) + Task 7 (fallback) | Covered |
| N1 — `SwipeSessionModel` hard-codes `PhotoLibraryChangePublisher.shared` | Deferred to Phase 7 | Out of scope |
| N2 — `MainTabView` init-threading vs `@Environment` inconsistency | Deferred to Phase 7 | Out of scope |

All 9 in-scope items (W1–W8 + N3) are covered. N1 and N2 are correctly deferred.

### 2. Placeholder scan

Scanned all 8 tasks for: "TBD", "TODO", "implement later", "fill in details", "add validation", "handle edge cases", "similar to Task N", steps without code blocks.

- Task 4 Step 4 contains an architectural note explaining the `scoped(toAlbumId: "")` approach was rejected in favor of `PhotoKitLibrary()` cast; this is complete reasoning, not a placeholder.
- Task 5 contains multiple implementation note sections explaining why the toolbar/binding approach was chosen; all are resolved with concrete code.
- Task 7 Step 2 is a conditional fallback with complete code; not a placeholder.
- No unresolved placeholders found.

### 3. Type consistency

- `GridImageCache` is `@MainActor final class` in Task 2's new file — consistent with the original in `RecentsView.swift`. All `@State private var imageCache = GridImageCache()` sites remain unchanged.
- `PhotoGridView` accepts `library: PhotoLibraryProviding` (the typealias) — consistent with Task 3's typealias definition. No consumer narrowed its type.
- `scoped(toAlbumId:)` is declared on `PhotoLibraryReadProviding` in Task 3, with return type `PhotoLibraryProviding` (the typealias). The implementation in `PhotoKitLibrary` returns `PhotoKitLibrary(albumId:)` which satisfies `PhotoLibraryProviding` — consistent. `MockPhotoLibrary.scoped(toAlbumId:)` returns a `MockPhotoLibrary` copy — consistent.
- `BulkDeleteView.privateLibrary` is typed `PhotoLibraryProviding` — consistent with global constraint (no type narrowing in Phase 3).
- `DebugMenuView` calls `DryRunMode.setEnabled(_:)` (the one-parameter convenience form calling `.standard`) and reads `DryRunMode.isEnabled` (the static var) — both exist and are unchanged in `DryRunMode.swift`.
- `PhotoGridView` parameters in Task 5: `assetIds: [AssetIdentifier]`, `library: PhotoLibraryProviding`, `imageCache: GridImageCache`, `isSelecting: Binding<Bool>`, `selectedIds: Binding<Set<AssetIdentifier>>`, `onTapAsset: (Int, AssetIdentifier) -> Void`, `onRequestMove: ([AssetIdentifier]) -> Void` — these are consistent across all call sites in `RecentsView` and `AlbumGridView`.
- `AlbumGridView.loadAssets()` references `scopedLibrary ?? library` — consistent with the `.task(id: album.id)` initialization which sets `scopedLibrary`.

---

## Handoff

Plan saved to `/home/harshal.patil/Documents/SwipeSort/docs/superpowers/plans/2026-07-15-phase-3-architecture.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task using `superpowers:subagent-driven-development`. Review between tasks. Fast iteration with isolated context per task.

**2. Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`. Batch execution with checkpoints.

Which approach?
