import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Settings file parsing
extension KeyboardShortcutSettingsFileStoreStartupTests {
    func testSettingsFileStoreParsesNumberedShortcutWithoutConsultingActiveShortcutStore() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let activeSettingsFileURL = directoryURL.appendingPathComponent("active.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "openBrowser": "cmd+3"
              }
            }
            """,
            to: activeSettingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: activeSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .openBrowser),
            StoredShortcut(key: "3", command: true, shift: false, option: false, control: false)
        )

        let parsedSettingsFileURL = directoryURL.appendingPathComponent("parsed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "selectWorkspaceByNumber": "cmd+7"
              }
            }
            """,
            to: parsedSettingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: parsedSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        )
    }

    func testSettingsFileShortcutNormalizationAcceptsRecorderConflictingShortcut() {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        let shortcut = StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.openBrowser.normalizedSettingsFileShortcut(shortcut),
            shortcut
        )
    }

    func testSettingsFileParsesMarkdownTypographyDefaults() throws {
        let defaults = UserDefaults.standard

        try preservingDefaults(keys: [
            MarkdownFontSizeSettings.key,
            MarkdownFontFamily.key,
            MarkdownMaxWidthSettings.key,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey
        ]) {
            defaults.removeObject(forKey: MarkdownFontSizeSettings.key)
            defaults.removeObject(forKey: MarkdownFontFamily.key)
            defaults.removeObject(forKey: MarkdownMaxWidthSettings.key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "markdown": {
                    "fontSize": 22,
                    "fontFamily": "  Avenir Next  \\n",
                    "maxWidth": 1220
                  }
                }
                """,
                to: settingsFileURL
            )

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            withExtendedLifetime(store) {
                XCTAssertEqual(defaults.integer(forKey: MarkdownFontSizeSettings.key), 22)
                XCTAssertEqual(defaults.string(forKey: MarkdownFontFamily.key), "Avenir Next")
                XCTAssertEqual(defaults.integer(forKey: MarkdownMaxWidthSettings.key), 1220)
            }
        }
    }

    func testSettingsFileParsesFileEditorWordWrap() throws {
        let defaults = UserDefaults.standard

        try preservingDefaults(keys: [
            FilePreviewWordWrapSettings.key,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey
        ]) {
            defaults.removeObject(forKey: FilePreviewWordWrapSettings.key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            // Defaults to off until the config opts in.
            XCTAssertFalse(FilePreviewWordWrapSettings.isEnabled(defaults: defaults))

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "fileEditor": {
                    "wordWrap": true
                  }
                }
                """,
                to: settingsFileURL
            )

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            withExtendedLifetime(store) {
                XCTAssertTrue(defaults.bool(forKey: FilePreviewWordWrapSettings.key))
                XCTAssertTrue(FilePreviewWordWrapSettings.isEnabled(defaults: defaults))
            }
        }
    }

}
