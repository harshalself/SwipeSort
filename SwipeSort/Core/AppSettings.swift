import Foundation
import Observation

/// The color-scheme preference for the app's user interface.
enum ThemeMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark
}



/// User-facing preferences, persisted in `UserDefaults` and observable by SwiftUI.
///
/// Injected from the app root via `@Environment(AppSettings.self)` so any
/// view can read live values without threading them through init parameters.
///
/// Each stored property uses `didSet` to write back to `UserDefaults`, which
/// lets `@Observable` track the mutation and invalidate dependent views.
@Observable
final class AppSettings {

    private enum Key {
        static let themeMode = "settings.themeMode"
        static let autoplayVideos = "settings.autoplayVideos"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let hiddenAlbumIds = "settings.hiddenAlbumIds"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Key.themeMode) }
    }

    var autoplayVideos: Bool {
        didSet { defaults.set(autoplayVideos, forKey: Key.autoplayVideos) }
    }

    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) }
    }

    var hiddenAlbumIds: Set<String> {
        didSet { defaults.set(Array(hiddenAlbumIds), forKey: Key.hiddenAlbumIds) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        // Wipe persisted settings at the start of every UI-test launch so
        // tests are isolated from each other regardless of execution order.
        if CommandLine.arguments.contains("--ui-testing")
            || CommandLine.arguments.contains("--ui-testing-empty")
            || CommandLine.arguments.contains("--ui-testing-denied")
            || CommandLine.arguments.contains("--ui-testing-single-photo") {
            [Key.themeMode, Key.autoplayVideos,
             Key.hapticsEnabled, Key.hiddenAlbumIds]
                .forEach { defaults.removeObject(forKey: $0) }
        }
        #endif
        self.themeMode = Self.readRaw(defaults, key: Key.themeMode, fallback: .system)

        self.autoplayVideos = Self.read(defaults, key: Key.autoplayVideos, fallback: true)
        self.hapticsEnabled = Self.read(defaults, key: Key.hapticsEnabled, fallback: true)
        if let array = defaults.stringArray(forKey: Key.hiddenAlbumIds) {
            self.hiddenAlbumIds = Set(array)
        } else {
            self.hiddenAlbumIds = []
        }
    }

    private static func read<T>(_ defaults: UserDefaults, key: String, fallback: T) -> T {
        (defaults.object(forKey: key) as? T) ?? fallback
    }

    private static func readRaw<T: RawRepresentable>(_ defaults: UserDefaults, key: String, fallback: T) -> T
        where T.RawValue == String {
        guard let raw = defaults.string(forKey: key),
              let v = T(rawValue: raw) else { return fallback }
        return v
    }
}
