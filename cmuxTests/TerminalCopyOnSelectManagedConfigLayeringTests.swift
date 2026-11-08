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
            ) == "term = \(TerminalSurface.managedTerminalType)"
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

        #expect(try Self.ghosttyTerm(afterLoading: managedConfig) == TerminalSurface.managedTerminalType)
    }

    private static func ghosttyTerm(afterLoading configContents: String?) throws -> String? {
        let configContents = try #require(configContents)
        let config = try #require(ghostty_config_new())
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

        #expect(ghostty_config_diagnostics_count(config) == 0)
        // `term` is a Zig byte slice, which ghostty_config_get does not expose.
        // Read the effective value from the real parser's serialized result.
        let exported = ghostty_config_serialize(config)
        defer { ghostty_string_free(exported) }
        let pointer = try #require(exported.ptr)
        let contents = String(decoding: Data(bytes: pointer, count: Int(exported.len)), as: UTF8.self)
        return effectiveGhosttyValues(afterLoading: [contents])["term"]
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
