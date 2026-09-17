import Foundation
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalCopyOnSelectManagedConfigLayeringTests {
    @Test(arguments: ["true", "false", "clipboard"])
    func disabledManagedSettingsPreserveDocumentedGhosttyCopyOnSelectValues(_ ghosttyValue: String) throws {
        let suiteName = "cmux-terminal-copy-on-select-layering-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: TerminalCopyOnSelectSettings.copyOnSelectKey)

        let effectiveValue = Self.effectiveGhosttyValues(afterLoading: [
            "copy-on-select = \(ghosttyValue)",
            TerminalManagedGhosttySettings.ghosttyConfigContents(
                defaults: defaults,
                emitsCopyOnSelectFalse: false
            ),
        ])["copy-on-select"]

        #expect(effectiveValue == ghosttyValue)
    }

    @Test
    func unsetManagedSettingsPreserveDocumentedGhosttyCopyOnSelectValues() throws {
        let suiteName = "cmux-terminal-copy-on-select-unset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            TerminalManagedGhosttySettings.ghosttyConfigContents(
                defaults: defaults,
                emitsCopyOnSelectFalse: false
            ) == nil
        )

        for ghosttyValue in ["true", "false", "clipboard"] {
            let effectiveValue = Self.effectiveGhosttyValues(afterLoading: [
                "copy-on-select = \(ghosttyValue)",
                TerminalManagedGhosttySettings.ghosttyConfigContents(
                    defaults: defaults,
                    emitsCopyOnSelectFalse: false
                ),
            ])["copy-on-select"]

            #expect(effectiveValue == ghosttyValue)
        }
    }

    @Test
    func enabledManagedSettingsRequestSystemClipboardCopyOnSelect() throws {
        let suiteName = "cmux-terminal-copy-on-select-enabled-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: TerminalCopyOnSelectSettings.copyOnSelectKey)

        #expect(
            TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults)
                == "term = \(TerminalSurface.managedTerminalType)\ncopy-on-select = clipboard"
        )

        let effectiveValue = Self.effectiveGhosttyValues(afterLoading: [
            "copy-on-select = false",
            TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults),
        ])["copy-on-select"]

        #expect(effectiveValue == "clipboard")
    }

    @Test
    func managedSettingsDoNotClobberOtherClipboardAndSelectionSettings() throws {
        let suiteName = "cmux-terminal-copy-on-select-neighbors-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: TerminalCopyOnSelectSettings.copyOnSelectKey)

        let effectiveValues = Self.effectiveGhosttyValues(afterLoading: [
            """
            copy-on-select = clipboard
            clipboard-read = allow
            clipboard-write = allow
            selection-clear-on-copy = true
            selection-clear-on-typing = false
            selection-word-chars = "_-"
            right-click-action = copy-or-paste
            mouse-reporting = false
            """,
            TerminalManagedGhosttySettings.ghosttyConfigContents(
                defaults: defaults,
                emitsCopyOnSelectFalse: false
            ),
        ])

        #expect(effectiveValues["copy-on-select"] == "clipboard")
        #expect(effectiveValues["clipboard-read"] == "allow")
        #expect(effectiveValues["clipboard-write"] == "allow")
        #expect(effectiveValues["selection-clear-on-copy"] == "true")
        #expect(effectiveValues["selection-clear-on-typing"] == "false")
        #expect(effectiveValues["selection-word-chars"] == "\"_-\"")
        #expect(effectiveValues["right-click-action"] == "copy-or-paste")
        #expect(effectiveValues["mouse-reporting"] == "false")
    }

    @Test
    func managedSettingsSetGhosttyTerminalIdentity() throws {
        let suiteName = "cmux-terminal-term-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let managedConfig = TerminalManagedGhosttySettings.ghosttyConfigContents(
            defaults: defaults,
            emitsCopyOnSelectFalse: false
        )

        #expect(Self.ghosttyTerm(afterLoading: managedConfig) == TerminalSurface.managedTerminalType)
    }

    private static func ghosttyTerm(afterLoading configContents: String?) -> String? {
        guard let configContents, let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }

        let syntheticPath = "/__cmux_test__/managed-terminal-settings.conf"
        configContents.withCString { contents in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(configContents.utf8.count),
                    path
                )
            }
        }
        ghostty_config_finalize(config)

        guard ghostty_config_diagnostics_count(config) == 0 else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "term"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else {
            return nil
        }
        return String(cString: value)
    }

    private static func effectiveGhosttyValues(afterLoading configs: [String?]) -> [String: String] {
        var values: [String: String] = [:]
        for config in configs.compactMap({ $0 }) {
            for line in config.components(separatedBy: .newlines) {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { continue }
                guard let separatorRange = trimmedLine.range(of: "=") else { continue }
                let key = trimmedLine[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
                values[String(key)] = trimmedLine[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return values
    }
}
