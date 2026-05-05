import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ShortcutSettingsNotificationCounter: @unchecked Sendable {
    var count = 0
}

private final class ShortcutSettingsLookupRecorder: @unchecked Sendable {
    var actions: [String] = []
}

final class KeyboardShortcutSettingsFileStoreMigrationTests: XCTestCase {
    func testBootstrapMigratesLegacySettingsIntoCanonicalConfig() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/cmux.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )

        let primaryContents = try String(contentsOf: primaryURL, encoding: .utf8)
        XCTAssertTrue(primaryContents.contains(#""$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json""#))
        XCTAssertTrue(primaryContents.contains(#""showNotifications": "cmd+i""#))
    }

    func testCanonicalConfigOverridesLegacySettingsPerKey() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("settings.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": "cmd+n",
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )
        try writeSettingsFile(
            """
            {
              "actions": {
                "local-action": {
                  "type": "builtin",
                  "id": "cmux.newTerminal"
                }
              },
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: primaryURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
    }

    func testLegacySettingsShortcutBindingsParseWithoutRuntimeConflictLookup() throws {
        let originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.shortcutLookupObserver = nil
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            KeyboardShortcutSettings.resetAll()
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let liveSettingsFileURL = directoryURL.appendingPathComponent("live-cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "openBrowser": "cmd+2"
              }
            }
            """,
            to: liveSettingsFileURL
        )
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: liveSettingsFileURL.path,
            fallbackPath: nil,
            notificationCenter: NotificationCenter(),
            startWatching: false
        )
        let lookupRecorder = ShortcutSettingsLookupRecorder()
        KeyboardShortcutSettings.shortcutLookupObserver = { action in
            lookupRecorder.actions.append(action.rawValue)
        }

        let primaryURL = directoryURL.appendingPathComponent("primary/cmux.json", isDirectory: false)
        let legacySettingsURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        let parsingNotificationCenter = NotificationCenter()
        let defaultNotificationCounter = ShortcutSettingsNotificationCounter()
        let parsingNotificationCounter = ShortcutSettingsNotificationCounter()
        let defaultNotificationObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            defaultNotificationCounter.count += 1
        }
        let parsingNotificationObserver = parsingNotificationCenter.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            parsingNotificationCounter.count += 1
        }
        defer {
            NotificationCenter.default.removeObserver(defaultNotificationObserver)
            parsingNotificationCenter.removeObserver(parsingNotificationObserver)
        }
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "bindings": {
                  "selectWorkspaceByNumber": "cmd+2"
                }
              }
            }
            """,
            to: legacySettingsURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: legacySettingsURL.path,
            notificationCenter: parsingNotificationCenter,
            startWatching: false
        )

        XCTAssertEqual(lookupRecorder.actions, [])
        XCTAssertEqual(defaultNotificationCounter.count, 0)
        XCTAssertEqual(parsingNotificationCounter.count, 1)
        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
        )
    }

    func testSettingsFileURLForEditingReturnsCanonicalConfigWhenLegacyFallbackExists() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/cmux.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/settings.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, primaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))
        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
    }

    func testProjectConfigManagedDefaultPersistsUIEditBackToCmuxJSON() throws {
        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: defaultsKey)
        let originalBackups = defaults.object(forKey: "cmux.settingsFile.backups.v1")
        defer {
            restoreDefaultsValue(originalSetting, forKey: defaultsKey)
            restoreDefaultsValue(originalBackups, forKey: "cmux.settingsFile.backups.v1")
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebarAppearance": {
                "matchTerminalBackground": true
              }
            }
            """,
            to: primaryURL
        )

        let notificationCenter = NotificationCenter()
        var store: KeyboardShortcutSettingsFileStore?
        defer { store = nil }
        store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertEqual(defaults.object(forKey: defaultsKey) as? Bool, true)

        waitForSettingsFileChange(on: notificationCenter) {
            defaults.set(false, forKey: defaultsKey)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        XCTAssertEqual(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"), false)

        try XCTUnwrap(store).reload()
        XCTAssertEqual(defaults.object(forKey: defaultsKey) as? Bool, false)
    }

    func testSettingsFilePersistsUIEditBackToCmuxJSONWhenKeyIsMissing() throws {
        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: defaultsKey)
        let originalBackups = defaults.object(forKey: "cmux.settingsFile.backups.v1")
        defer { restoreDefaultsValue(originalSetting, forKey: defaultsKey); restoreDefaultsValue(originalBackups, forKey: "cmux.settingsFile.backups.v1") }
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile("{\n  \"schemaVersion\": 1\n}", to: primaryURL)
        let notificationCenter = NotificationCenter()
        var store: KeyboardShortcutSettingsFileStore?
        defer { store = nil }
        store = KeyboardShortcutSettingsFileStore(primaryPath: primaryURL.path, fallbackPath: nil, notificationCenter: notificationCenter, startWatching: true)
        XCTAssertNil(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"))

        waitForSettingsFileChange(on: notificationCenter) {
            defaults.set(true, forKey: defaultsKey)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        XCTAssertEqual(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"), true)
        try XCTUnwrap(store).reload()
        XCTAssertEqual(defaults.object(forKey: defaultsKey) as? Bool, true)
    }
    func testProjectConfigManagedDefaultWriteBackPreservesJSONCComments() throws {
        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: defaultsKey)
        let originalBackups = defaults.object(forKey: "cmux.settingsFile.backups.v1")
        defer {
            restoreDefaultsValue(originalSetting, forKey: defaultsKey)
            restoreDefaultsValue(originalBackups, forKey: "cmux.settingsFile.backups.v1")
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              // Keep this comment when the Settings UI writes back.
              "sidebarAppearance": {
                "matchTerminalBackground": true /* inline note */
              }
            }
            """,
            to: primaryURL
        )

        let notificationCenter = NotificationCenter()
        var store: KeyboardShortcutSettingsFileStore?
        defer { store = nil }
        store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertEqual(store?.activeSourcePath, primaryURL.path)

        waitForSettingsFileChange(on: notificationCenter) {
            defaults.set(false, forKey: defaultsKey)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        let contents = try String(contentsOf: primaryURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("// Keep this comment"))
        XCTAssertTrue(contents.contains("/* inline note */"))
        XCTAssertEqual(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"), false)
    }

    func testProjectConfigManagedDefaultWriteBackSupportsUTF16SettingsFile() throws {
        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: defaultsKey)
        let originalBackups = defaults.object(forKey: "cmux.settingsFile.backups.v1")
        defer {
            restoreDefaultsValue(originalSetting, forKey: defaultsKey)
            restoreDefaultsValue(originalBackups, forKey: "cmux.settingsFile.backups.v1")
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebarAppearance": {
                "matchTerminalBackground": true
              }
            }
            """,
            to: primaryURL,
            encoding: .utf16
        )

        let notificationCenter = NotificationCenter()
        var store: KeyboardShortcutSettingsFileStore?
        defer { store = nil }
        store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertEqual(defaults.object(forKey: defaultsKey) as? Bool, true)

        waitForSettingsFileChange(on: notificationCenter) {
            defaults.set(false, forKey: defaultsKey)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        XCTAssertEqual(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"), false)
        XCTAssertNotNil(try String(data: Data(contentsOf: primaryURL), encoding: .utf16))
        XCTAssertNotNil(store)
    }

    func testProjectConfigManagedDefaultWriteBackPreservesFilePermissions() throws {
        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaults = UserDefaults.standard
        let originalSetting = defaults.object(forKey: defaultsKey)
        let originalBackups = defaults.object(forKey: "cmux.settingsFile.backups.v1")
        defer {
            restoreDefaultsValue(originalSetting, forKey: defaultsKey)
            restoreDefaultsValue(originalBackups, forKey: "cmux.settingsFile.backups.v1")
        }

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebarAppearance": {
                "matchTerminalBackground": true
              }
            }
            """,
            to: primaryURL
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: primaryURL.path)

        let notificationCenter = NotificationCenter()
        var store: KeyboardShortcutSettingsFileStore?
        defer { store = nil }
        store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertEqual(defaults.object(forKey: defaultsKey) as? Bool, true)

        waitForSettingsFileChange(on: notificationCenter) {
            defaults.set(false, forKey: defaultsKey)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: primaryURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(try boolSetting(in: primaryURL, section: "sidebarAppearance", key: "matchTerminalBackground"), false)
        XCTAssertNotNil(store)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(
        _ contents: String,
        to url: URL,
        encoding: String.Encoding = .utf8
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: encoding)
    }

    private func restoreDefaultsValue(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func waitForSettingsFileChange(
        on notificationCenter: NotificationCenter,
        after action: () -> Void
    ) {
        let expectation = expectation(description: "Settings file change notification")
        let observer = notificationCenter.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        action()
        wait(for: [expectation], timeout: 2.0)
        notificationCenter.removeObserver(observer)
    }

    private func boolSetting(in url: URL, section: String, key: String) throws -> Bool? {
        let data = try Data(contentsOf: url)
        let sanitized = try JSONCParser.preprocess(data: data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: []) as? [String: Any]
        let settingsSection = object?[section] as? [String: Any]
        return settingsSection?[key] as? Bool
    }
}
