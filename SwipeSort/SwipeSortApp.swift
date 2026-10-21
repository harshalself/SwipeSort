import SwiftUI

/// The app entry point.
///
/// Creates a single `AppSettings` instance and injects it into the environment
/// so any descendant view can read preferences without parameter threading.
/// `preferredColorScheme` is applied at the window level so the theme takes
/// effect even before any view reads `settings.themeMode`.
@main
struct SwipeSortApp: App {
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(settings)
                .preferredColorScheme(colorScheme(for: settings.themeMode))
        }
    }

    private func colorScheme(for mode: ThemeMode) -> ColorScheme? {
        switch mode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
