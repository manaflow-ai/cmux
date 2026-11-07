import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A session restore can finish after the start-up pass, and it drops every status row. While
/// the setting is on, its completion asks for the settled reconcile pass that rebuilds the rows
/// and targets of the restored Claude panes.
///
/// Serialized and synchronous on the main actor: it writes the standard defaults key the
/// coordinator reads.
@Suite(.serialized)
@MainActor
struct SessionPriorityRestoreCompletionTests {
    private static let defaultsKey = "sessionPriorityEnabled"

    private func withSetting(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.defaultsKey)
        defaults.set(enabled, forKey: Self.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
        }
        body()
    }

    @Test
    func restoreCompletionAsksForAPassOnlyWhileOn() {
        let coordinator = SessionPriorityCoordinator()
        withSetting(true) {
            #expect(coordinator.state.reconcileDueAtMs == nil)
            coordinator.sessionRestoreDidComplete()
            #expect(coordinator.state.reconcileDueAtMs != nil)
            // Remembers the setting as on, so turning it off below drops the pending pass.
            coordinator.settingsDidChange()
        }
        withSetting(false) {
            coordinator.settingsDidChange()
            #expect(coordinator.state.reconcileDueAtMs == nil)
            coordinator.sessionRestoreDidComplete()
            #expect(coordinator.state.reconcileDueAtMs == nil)
        }
    }
}
