import AppKit
import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the focused-split border feature (issue #6709):
/// the `TerminalFocusedSplitBorderSettings` resolvers and the end-to-end
/// `terminal.focusedSplitBorder*` cmux.json parsing path.
@Suite("Terminal focused split border settings", .serialized)
struct TerminalFocusedSplitBorderSettingsTests {
    private let focusedSplitBorderSettings = TerminalFocusedSplitBorderSettings()
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    // MARK: - Resolver unit tests

    @Test
    func enabledDefaultsToTrueWhenUnset() {
        let defaults = ephemeralDefaults()
        #expect(focusedSplitBorderSettings.isEnabled(defaults: defaults) == true)
    }

    @Test
    func enabledReadsStoredValue() {
        let defaults = ephemeralDefaults()
        defaults.set(false, forKey: TerminalFocusedSplitBorderSettings.enabledKey)
        #expect(focusedSplitBorderSettings.isEnabled(defaults: defaults) == false)
    }

    @Test
    func widthClampsToSupportedRange() {
        #expect(
            focusedSplitBorderSettings.sanitizedWidth(99)
                == TerminalFocusedSplitBorderSettings.maximumWidth
        )
        #expect(
            focusedSplitBorderSettings.sanitizedWidth(0)
                == TerminalFocusedSplitBorderSettings.minimumWidth
        )
        #expect(focusedSplitBorderSettings.sanitizedWidth(3) == 3)
        // Non-finite input falls back to the default rather than propagating NaN.
        #expect(
            focusedSplitBorderSettings.sanitizedWidth(.nan)
                == TerminalFocusedSplitBorderSettings.defaultWidth
        )
    }

    @Test
    func widthDefaultsWhenUnset() {
        let defaults = ephemeralDefaults()
        #expect(
            focusedSplitBorderSettings.resolvedWidth(defaults: defaults)
                == TerminalFocusedSplitBorderSettings.defaultWidth
        )
    }

    @Test
    func colorResolvesValidHexOverride() {
        #expect(
            focusedSplitBorderSettings.resolvedColor(colorHex: "#ff8800").hexString() == "#FF8800"
        )
    }

    @Test
    func colorFallsBackToAccentForMissingOrInvalidHex() {
        let accent = cmuxAccentNSColor().hexString()
        #expect(focusedSplitBorderSettings.resolvedColor(colorHex: nil).hexString() == accent)
        #expect(focusedSplitBorderSettings.resolvedColor(colorHex: "").hexString() == accent)
        #expect(focusedSplitBorderSettings.resolvedColor(colorHex: "not-a-color").hexString() == accent)
    }

    // MARK: - cmux.json parsing (issue #6709 repro path)

    @Test
    func settingsFileDisablesFocusedSplitBorder() throws {
        try loadTerminalSection("\"focusedSplitBorder\": false") { defaults in
            #expect(defaults.object(forKey: TerminalFocusedSplitBorderSettings.enabledKey) as? Bool == false)
            #expect(focusedSplitBorderSettings.isEnabled(defaults: defaults) == false)
        }
    }

    @Test
    func settingsFileAppliesColorOverride() throws {
        try loadTerminalSection("\"focusedSplitBorderColor\": \"#ff8800\"") { defaults in
            #expect(focusedSplitBorderSettings.resolvedColorHex(defaults: defaults) == "#FF8800")
        }
    }

    @Test
    func settingsFileClampsBorderWidth() throws {
        try loadTerminalSection("\"focusedSplitBorderWidth\": 99") { defaults in
            #expect(
                defaults.object(forKey: TerminalFocusedSplitBorderSettings.widthKey) as? Double
                    == TerminalFocusedSplitBorderSettings.maximumWidth
            )
            #expect(
                focusedSplitBorderSettings.resolvedWidth(defaults: defaults)
                    == TerminalFocusedSplitBorderSettings.maximumWidth
            )
        }
    }

    @Test
    func settingsFileNullColorClearsOverride() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            TerminalFocusedSplitBorderSettings.colorHexKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            // Seed a stale override so the null in the file has something to clear.
            defaults.set("#123456", forKey: TerminalFocusedSplitBorderSettings.colorHexKey)
            try loadTerminalSectionPreservingExternally("\"focusedSplitBorderColor\": null") { defaults in
                #expect(focusedSplitBorderSettings.resolvedColorHex(defaults: defaults) == nil)
            }
        }
    }

    // MARK: - Helpers

    private func ephemeralDefaults() -> UserDefaults {
        let suite = "cmux.test.focusedSplitBorder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func loadTerminalSection(_ terminalBody: String, verify: (UserDefaults) throws -> Void) throws {
        try preservingDefaults(keys: [
            TerminalFocusedSplitBorderSettings.enabledKey,
            TerminalFocusedSplitBorderSettings.colorHexKey,
            TerminalFocusedSplitBorderSettings.widthKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            try loadTerminalSectionPreservingExternally(terminalBody, verify: verify)
        }
    }

    /// Loads a terminal-section cmux.json without managing the
    /// focused-split-border defaults itself, so callers that need to seed
    /// values (e.g. the null-clear case) can control them.
    private func loadTerminalSectionPreservingExternally(
        _ terminalBody: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "terminal": {
            \(terminalBody)
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        try verify(UserDefaults.standard)
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-focused-split-border-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
