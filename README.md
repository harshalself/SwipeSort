# SwipeSort

**SwipeSort** is a high-performance, swipe-based iOS photo triage and organization app built with SwiftUI and PhotoKit. It allows users to quickly review, favorite, move to albums, and bulk-delete photos and videos using intuitive gesture controls.

---

## Features

- **Tinder-Style Swipe Deck**: Rapid photo triage with card deck gestures (swipe to keep/favorite, delete, or swipe up to move to custom albums).
- **Video & Live Photo Support**: Seamless card deck playback with an efficient `AVPlayer` pool and Live Photo hints.
- **Index-Driven Lazy Grid**: High-performance scrolling in Recents and Albums views backed by `LazyIndexedCell` and `WindowedThumbnailCache` for smooth 60/120 fps scrolling across large photo libraries (50k+ items).
- **Safe Batch Deletion**: Destructive actions are queued in `DeletionQueueView` for final user confirmation before committing through `PHPhotoLibrary`.
- **Dry-Run Safety Switch**: Built-in developer safety mode (`DryRunMode`) preventing accidental deletions during local development and testing.
- **Filters & Sorting**: Filter by media type (Photos, Videos, Live Photos), date ranges, and custom sorting.
- **Configurable Settings**: Customizable swipe gestures, haptic feedback, video autoplay threshold, and theme selection.

---

## Project Structure

```
SwipeSort/
├── SwipeSortApp.swift             # Main SwiftUI App entry point
├── Info.plist                     # App configurations & PhotoKit permissions
├── Core/                          # Architecture foundation & models
│   ├── PhotoLibraryProviding.swift # Protocol abstractions (ReadProviding, CacheProviding, Mutating)
│   ├── PhotoKitLibrary.swift      # Production PhotoKit implementation
│   ├── MockPhotoLibrary.swift     # In-memory test double for unit testing
│   ├── SwipeSessionModel.swift    # Swipe session management & prefetching
│   ├── SwipeDecision.swift        # Swipe decisions & FIFO action queue
│   ├── SwipeFilter.swift          # Media type and date predicates
│   ├── WindowedThumbnailCache.swift # Sliding-window prefetching cache
│   ├── VideoPlayerPool.swift      # Recycled AVPlayer instances
│   ├── DryRunMode.swift           # Deletion kill-switch for safety
│   ├── AppSettings.swift          # User preferences observable
│   └── UserAlbum.swift            # Album metadata model
├── Features/
│   ├── MainTabView.swift          # Primary tab bar (Recents, Albums, Settings)
│   ├── Landing/                   # Browse views (RecentsView, AlbumsView, FilterSheet)
│   ├── Swipe/                     # Swipe deck views (SwipeStackView, Card views, DeletionQueueView)
│   ├── Components/                # Shared grid (PhotoGridView, LazyIndexedCell, ThumbnailCell)
│   └── Settings/                  # SettingsView, AboutView
└── Assets.xcassets/               # App icons and color catalog

SwipeSortTests/                   # Swift Testing suite (24 test suites)
SwipeSortUITests/                 # XCUITest integration and UI automation
docs/
├── RESEARCH.md                   # Technical reference on PhotoKit, AVPlayer & SwiftUI performance
├── reviews/                      # Code audit logs
└── superpowers/                  # Architecture specs & version roadmap
```

---

## Building and Testing

### Requirements
- macOS 14+
- Xcode 15.0+ (supports Xcode 16 synchronized folder groups)
- iOS 17.0+ deployment target

### Open in Xcode
Open [`SwipeSort.xcodeproj`](SwipeSort.xcodeproj) in Xcode:
- `⌘B` to build the app
- `⌘U` to run the test suite
- `⌘R` to launch in the iOS Simulator

### Command Line
```bash
# Build the application
xcodebuild -scheme SwipeSort -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# Build tests
xcodebuild build-for-testing -scheme SwipeSort -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

---

## Safety & Permissions

- **Photo Library Access**: Requests `.readWrite` PhotoKit access to fetch and organize assets.
- **Dry-Run Mode**: Defaults to enabled in debug builds (`UserDefaults` key `dryRunMode`). In dry-run mode, all deletions and moves are simulated and logged without touching the user's actual photo library. To test real deletions, toggle Dry-Run Mode via the debug menu accessible by long-pressing the navigation title in `SwipeStackView`.
