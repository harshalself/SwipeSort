import Testing
import Foundation
@testable import SwipeSort

@Suite("AppSettings")
struct AppSettingsTests {

    /// Each test gets its own isolated UserDefaults suite so writes from
    /// one test can't bleed into the next. `.standard` would persist across
    /// runs and give false negatives on "safe defaults."
    private func freshDefaults() -> UserDefaults {
        let name = UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("safe defaults on a fresh install")
    func defaults() {
        let s = AppSettings(defaults: freshDefaults())
        #expect(s.themeMode == .system)
        #expect(s.autoplayVideos == true)
        #expect(s.hapticsEnabled == true)
    }

    @Test("theme persists across instances")
    func themePersists() {
        let d = freshDefaults()
        do {
            let s = AppSettings(defaults: d)
            s.themeMode = .dark
        }
        let s2 = AppSettings(defaults: d)
        #expect(s2.themeMode == .dark)
    }

    @Test("all toggles round-trip")
    func togglesPersist() {
        let d = freshDefaults()
        let s = AppSettings(defaults: d)
        s.autoplayVideos = false
        s.hapticsEnabled = false

        let s2 = AppSettings(defaults: d)
        #expect(s2.autoplayVideos == false)
        #expect(s2.hapticsEnabled == false)
    }
}
