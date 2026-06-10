import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Confirm-quit import and legacy migration
extension KeyboardShortcutSettingsFileStoreStartupTests {
    func testConfirmQuitImportsEnumFromCmuxJSON() throws {
        let defaults = UserDefaults.standard
        let key = QuitWarningSettings.confirmQuitKey

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
                  "app": {
                    "confirmQuit": "dirty-only"
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

            XCTAssertEqual(defaults.string(forKey: key), QuitConfirmationMode.dirtyOnly.rawValue)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .dirtyOnly)
        }
    }

    func testLegacyWarnBeforeQuitMapsToConfirmQuitWhenConfirmQuitIsAbsent() throws {
        let defaults = UserDefaults.standard
        let confirmQuitKey = QuitWarningSettings.confirmQuitKey
        let warnBeforeQuitKey = QuitWarningSettings.warnBeforeQuitKey

        try preservingDefaults(keys: [
            confirmQuitKey,
            warnBeforeQuitKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.set(QuitConfirmationMode.always.rawValue, forKey: confirmQuitKey)
            defaults.removeObject(forKey: warnBeforeQuitKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "app": {
                    "warnBeforeQuit": false
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

            XCTAssertEqual(defaults.string(forKey: confirmQuitKey), QuitConfirmationMode.never.rawValue)
            XCTAssertEqual(defaults.object(forKey: warnBeforeQuitKey) as? Bool, false)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .never)
        }
    }

    func testLegacyWarnBeforeQuitMigrationPreservesUserOverride() throws {
        let defaults = UserDefaults.standard
        let confirmQuitKey = QuitWarningSettings.confirmQuitKey
        let warnBeforeQuitKey = QuitWarningSettings.warnBeforeQuitKey

        try preservingDefaults(keys: [
            confirmQuitKey,
            warnBeforeQuitKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: confirmQuitKey)
            defaults.set(true, forKey: warnBeforeQuitKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.set(
                Data(#"{"warnBeforeQuitShortcut":{"bool":{"_0":false}}}"#.utf8),
                forKey: importedManagedDefaultsKey
            )

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "app": {
                    "warnBeforeQuit": false
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

            XCTAssertNil(defaults.string(forKey: confirmQuitKey))
            XCTAssertEqual(defaults.object(forKey: warnBeforeQuitKey) as? Bool, true)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .always)

            try writeSettingsFile("{}", to: settingsFileURL)
            store.reload()

            XCTAssertNil(defaults.string(forKey: confirmQuitKey))
            XCTAssertEqual(defaults.object(forKey: warnBeforeQuitKey) as? Bool, true)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .always)
        }
    }

    func testInvalidConfirmQuitDoesNotAbortRemainingAppSettings() throws {
        let defaults = UserDefaults.standard
        let confirmQuitKey = QuitWarningSettings.confirmQuitKey
        let warnBeforeQuitKey = QuitWarningSettings.warnBeforeQuitKey

        try preservingDefaults(keys: [
            confirmQuitKey,
            warnBeforeQuitKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: confirmQuitKey)
            defaults.removeObject(forKey: warnBeforeQuitKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "app": {
                    "confirmQuit": "sometimes",
                    "warnBeforeQuit": false
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

            XCTAssertEqual(defaults.string(forKey: confirmQuitKey), QuitConfirmationMode.never.rawValue)
            XCTAssertEqual(defaults.object(forKey: warnBeforeQuitKey) as? Bool, false)
            XCTAssertEqual(QuitWarningSettings.confirmQuitMode(defaults: defaults), .never)
        }
    }

}
