import SwiftUI

/// The Settings tab.
///
/// Presents `AppSettings` properties as a SwiftUI `Form`. Wraps the
/// environment-provided `AppSettings` in a local `@Bindable` shadowing the
/// same name so pickers and toggles can bind directly via `$settings.foo`;
/// each mutation writes through to `UserDefaults` via the `didSet` observers
/// defined in `AppSettings`.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.themeMode) {
                        ForEach(ThemeMode.allCases, id: \.self) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                }

                Section {

                    Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
                } header: {
                    Text("Gestures")
                }

                Section("Video playback") {
                    Toggle("Autoplay videos", isOn: $settings.autoplayVideos)
                }



                Section {
                    NavigationLink("About SwipeSort") { AboutView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension ThemeMode {
    var displayName: String { rawValue.capitalized }
}


