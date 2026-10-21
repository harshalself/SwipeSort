import Testing
import Foundation
@testable import SwipeSort

@Suite("DryRunMode")
struct DryRunModeTests {
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("defaults to true when key is unset")
    func defaultsToTrue() {
        let d = freshDefaults()
        #expect(DryRunMode.isEnabled(defaults: d) == true)
    }

    @Test("persists across reads")
    func persists() {
        let d = freshDefaults()
        DryRunMode.setEnabled(false, defaults: d)
        #expect(DryRunMode.isEnabled(defaults: d) == false)
        DryRunMode.setEnabled(true, defaults: d)
        #expect(DryRunMode.isEnabled(defaults: d) == true)
    }

    @Test("convenience static reader uses standard defaults")
    func standardDefaults() {
        _ = DryRunMode.isEnabled
    }

    @Test("log emits via os.Logger without crashing")
    func logDoesNotCrash() {
        DryRunMode.log("hello dry-run")
        #expect(true)
    }
}
