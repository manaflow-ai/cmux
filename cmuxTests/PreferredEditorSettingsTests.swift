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

    // MARK: - Launch environment (#5817)
    //
    // GUI apps inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so a
    // bare editor command like `code` (installed in /usr/local/bin or
    // /opt/homebrew/bin) exits 127 and the setting silently appears to do
    // nothing. The launch environment must include the standard CLI
    // directories so bare commands resolve the way they do in a terminal.

    @Test func launchEnvironmentAppendsStandardCLIDirectoriesToGUIPath() {
        let environment = PreferredEditorSettings.launchEnvironment(
            base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        let path = environment["PATH"] ?? ""
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.contains("/usr/local/bin"))
        #expect(entries.contains("/opt/homebrew/bin"))
        // Inherited entries keep precedence over the appended directories.
        #expect(entries.first == "/usr/bin")
    }

    @Test func launchEnvironmentDoesNotDuplicateDirectoriesAlreadyOnPath() {
        let loginShellPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let environment = PreferredEditorSettings.launchEnvironment(
            base: ["PATH": loginShellPath]
        )
        #expect(environment["PATH"] == loginShellPath)
    }

    @Test func launchEnvironmentPreservesOtherVariables() {
        let environment = PreferredEditorSettings.launchEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/example", "LANG": "en_US.UTF-8"]
        )
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["LANG"] == "en_US.UTF-8")
    }

    @Test func launchEnvironmentProvidesUsablePathWhenBasePathMissingOrEmpty() {
        for base in [[String: String](), ["PATH": ""], ["PATH": "   "]] {
            let environment = PreferredEditorSettings.launchEnvironment(base: base)
            let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            #expect(
                entries.contains("/usr/bin") && entries.contains("/usr/local/bin"),
                "base \(base) should still yield a usable PATH, got \(entries)"
            )
        }
    }
}
