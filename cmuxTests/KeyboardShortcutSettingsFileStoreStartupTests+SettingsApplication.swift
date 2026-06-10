import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Applying individual settings
extension KeyboardShortcutSettingsFileStoreStartupTests {
    func testSettingsFileStoreAppliesTerminalAgentAutoResumeSetting() throws {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previousValue = defaults.object(forKey: key)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        let previousImportedDefaults = defaults.data(forKey: importedManagedDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
            if let previousImportedDefaults {
                defaults.set(previousImportedDefaults, forKey: importedManagedDefaultsKey)
            } else {
                defaults.removeObject(forKey: importedManagedDefaultsKey)
            }
        }

        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: importedManagedDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "terminal": {
                "autoResumeAgentSessions": false
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }

    func testSettingsFileStoreAppliesTerminalTextBoxMaxLinesSetting() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            TerminalTextBoxInputSettings.maxLinesKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: TerminalTextBoxInputSettings.maxLinesKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "textBoxMaxLines": 14
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.object(forKey: TerminalTextBoxInputSettings.maxLinesKey) as? Int, 14)
            XCTAssertEqual(TerminalTextBoxInputSettings.maxLines(defaults: defaults), 14)
        }
    }

    func testSettingsFileStoreAppliesFocusTextBoxOnNewTerminalsSetting() throws {
        let defaults = UserDefaults.standard
        let showKey = TerminalTextBoxInputSettings.showOnNewTerminalsKey
        let focusKey = TerminalTextBoxInputSettings.focusOnNewTerminalsKey
        try preservingDefaults(keys: [showKey, focusKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            defaults.removeObject(forKey: showKey)
            defaults.removeObject(forKey: focusKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "showTextBoxOnNewTerminals": true,
                    "focusTextBoxOnNewTerminals": true
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.object(forKey: showKey) as? Bool, true)
            XCTAssertEqual(defaults.object(forKey: focusKey) as? Bool, true)
            XCTAssertTrue(TerminalTextBoxInputSettings.showOnNewTerminals(defaults: defaults))
            XCTAssertTrue(TerminalTextBoxInputSettings.focusOnNewTerminals(defaults: defaults))
        }
    }

    func testSettingsFileStoreAppliesTerminalCopyOnSelectSetting() throws {
        let defaults = UserDefaults.standard
        let key = TerminalCopyOnSelectSettings.copyOnSelectKey

        try preservingDefaults(keys: [key, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "copyOnSelect": true
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
            XCTAssertEqual(
                TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
                "copy-on-select = clipboard"
            )
        }
    }

    func testSettingsFileStoreAppliesAutomationRipgrepBinaryPath() throws {
        let defaults = UserDefaults.standard
        let key = "ripgrepCustomBinaryPath"

        try preservingDefaults(keys: [key, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "automation": {
                    "ripgrepBinaryPath": "/etc/profiles/per-user/nixuser/bin/rg"
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: key), "/etc/profiles/per-user/nixuser/bin/rg")
        }
    }

    func testSettingsFileStoreAppliesCustomBrowserSearchEngine() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            BrowserSearchSettings.searchEngineKey,
            BrowserSearchSettings.customSearchEngineNameKey,
            BrowserSearchSettings.customSearchEngineURLTemplateKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: BrowserSearchSettings.searchEngineKey)
            defaults.removeObject(forKey: BrowserSearchSettings.customSearchEngineNameKey)
            defaults.removeObject(forKey: BrowserSearchSettings.customSearchEngineURLTemplateKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "browser": {
                    "defaultSearchEngine": "custom",
                    "customSearchEngineName": "Kagi Site Search",
                    "customSearchEngineURLTemplate": "https://kagi.com/search?q={query}"
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            let configuration = BrowserSearchSettings.currentConfiguration(defaults: defaults)
            let url = try XCTUnwrap(configuration.searchURL(query: "browser settings"))

            XCTAssertEqual(configuration.engine, .custom)
            XCTAssertEqual(configuration.displayName, "Kagi Site Search")
            XCTAssertEqual(url.host, "kagi.com")
            XCTAssertTrue(url.absoluteString.contains("q=browser%20settings"))
        }
    }

    func testSettingsFileStoreAppliesBlankCustomBrowserSearchNameAndIgnoresInvalidCustomURLWithoutAbortingBrowserSection() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            BrowserSearchSettings.searchEngineKey,
            BrowserSearchSettings.customSearchEngineNameKey,
            BrowserSearchSettings.customSearchEngineURLTemplateKey,
            BrowserSearchSettings.searchSuggestionsEnabledKey,
            BrowserThemeSettings.modeKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: BrowserSearchSettings.searchEngineKey)
            defaults.removeObject(forKey: BrowserSearchSettings.customSearchEngineNameKey)
            defaults.removeObject(forKey: BrowserSearchSettings.customSearchEngineURLTemplateKey)
            defaults.removeObject(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey)
            defaults.removeObject(forKey: BrowserThemeSettings.modeKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "browser": {
                    "defaultSearchEngine": "google",
                    "customSearchEngineName": "   ",
                    "customSearchEngineURLTemplate": "ftp://search.example.test?q={query}",
                    "showSearchSuggestions": false,
                    "theme": "dark"
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: BrowserSearchSettings.searchEngineKey), BrowserSearchEngine.google.rawValue)
            XCTAssertEqual(
                defaults.string(forKey: BrowserSearchSettings.customSearchEngineNameKey),
                BrowserSearchSettings.defaultCustomSearchEngineName
            )
            XCTAssertNotEqual(
                defaults.string(forKey: BrowserSearchSettings.customSearchEngineURLTemplateKey),
                "ftp://search.example.test?q={query}"
            )
            XCTAssertEqual(defaults.object(forKey: BrowserSearchSettings.searchSuggestionsEnabledKey) as? Bool, false)
            XCTAssertEqual(defaults.string(forKey: BrowserThemeSettings.modeKey), BrowserThemeMode.dark.rawValue)
        }
    }

    func testSettingsFileStoreRejectsInvalidTerminalTextBoxMaxLinesSetting() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            TerminalTextBoxInputSettings.maxLinesKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: TerminalTextBoxInputSettings.maxLinesKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "textBoxMaxLines": 100
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                startWatching: false
            )

            XCTAssertNil(defaults.object(forKey: TerminalTextBoxInputSettings.maxLinesKey))
            XCTAssertEqual(
                TerminalTextBoxInputSettings.maxLines(defaults: defaults),
                TerminalTextBoxInputSettings.defaultMaxLines
            )
        }
    }

}
