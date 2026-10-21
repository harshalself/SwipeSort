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
