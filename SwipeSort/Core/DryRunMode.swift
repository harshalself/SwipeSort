import Foundation
import os

/// Kill-switch for destructive PhotoKit operations, persisted in `UserDefaults`.
///
/// Every code path that deletes, moves, or otherwise mutates the photo library
/// must gate on `DryRunMode.isEnabled` and call `DryRunMode.log` instead of
/// executing when the flag is set.
///
/// Default is `true` (safe). The user can disable dry-run mode via the hidden
/// debug menu (long-press the swipe-screen title bar) — see `SwipeStackView`.
///
/// Why: the default-safe value means a fresh install or a missing defaults entry
/// never accidentally mutates the library, matching the "opt-in to real writes"
/// design contract.
enum DryRunMode {
    static let defaultsKey = "swipesort.dryRun"

    /// Returns `true` unless `UserDefaults` explicitly stores `false` for the key.
    ///
    /// A missing entry is treated as `true` (safe default).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(forKey: defaultsKey) as? Bool else { return true }
        return raw
    }

    /// Writes the dry-run flag to `UserDefaults`.
    static func setEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }

    /// Convenience accessor that reads from `UserDefaults.standard`.
    ///
    /// Why: prefer `isEnabled(defaults:)` in testable code so the injected
    /// suite is read instead of `.standard`, which always reflects the real device state.
    static var isEnabled: Bool { isEnabled() }

    private static let logger = Logger(subsystem: "com.harshalpatil.SwipeSort", category: "DryRun")

    /// Logs an intended destructive action without executing it.
    static func log(_ message: String) {
        logger.notice("[DRY-RUN] \(message, privacy: .public)")
    }
}
