import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavioral coverage for the editor-command resolver shared by every
/// cmux config-file opener (the workspace-group "Edit Group Configuration"
/// action, the "Open Cmux Settings File" action, and the Settings config
/// window). Verifies that a configured `preferredEditorCommand` is honored
/// and that an unset/blank value falls back to `nil` (the OS-default path).
@Suite struct PreferredEditorSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-preferred-editor-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func returnsNilWhenUnset() {
        let defaults = makeDefaults()
        #expect(PreferredEditorSettings.resolvedCommand(defaults: defaults) == nil)
    }

    @Test func returnsNilForEmptyOrWhitespaceCommand() {
        for raw in ["", "   ", "\n\t "] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: PreferredEditorSettings.key)
            #expect(
                PreferredEditorSettings.resolvedCommand(defaults: defaults) == nil,
                "blank command \(raw.debugDescription) should fall back to OS default"
            )
        }
    }

    @Test func returnsConfiguredCommandWhenSet() {
        let defaults = makeDefaults()
        defaults.set("code", forKey: PreferredEditorSettings.key)
        #expect(PreferredEditorSettings.resolvedCommand(defaults: defaults) == "code")
    }

    @Test func trimsSurroundingWhitespaceFromConfiguredCommand() {
        let defaults = makeDefaults()
        defaults.set("  code -w  \n", forKey: PreferredEditorSettings.key)
        #expect(PreferredEditorSettings.resolvedCommand(defaults: defaults) == "code -w")
    }
}
