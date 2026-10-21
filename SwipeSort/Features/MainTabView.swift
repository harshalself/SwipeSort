import SwiftUI

/// The root tab-bar container for the app.
///
/// Creates and holds the single shared `PhotoLibraryProviding` instance that
/// is passed down to `RecentsView` and `AlbumsView`. In UI-test runs,
/// `CommandLine.arguments` flags inject a `MockPhotoLibrary` with scripted
/// state so tests don't require a real photo library.
struct MainTabView: View {
    @State private var library: PhotoLibraryProviding = {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-testing-empty") {
            return MockPhotoLibrary(authorization: .authorized, assetCount: 0)
        }
        if CommandLine.arguments.contains("--ui-testing-denied") {
            return MockPhotoLibrary(authorization: .denied, assetCount: 0)
        }
        if CommandLine.arguments.contains("--ui-testing-single-photo") {
            return MockPhotoLibrary(authorization: .authorized, assetCount: 1)
        }
        if CommandLine.arguments.contains("--ui-testing") {
            return MockPhotoLibrary(authorization: .authorized, assetCount: 6)
        }
        #endif
        return PhotoKitLibrary()
    }()

    var body: some View {
        TabView {
            RecentsView(library: library)
                .tabItem {
                    Label("Recents", systemImage: "photo.on.rectangle")
                }

            AlbumsView(library: library)
                .tabItem {
                    Label("Albums", systemImage: "photo.stack")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}
