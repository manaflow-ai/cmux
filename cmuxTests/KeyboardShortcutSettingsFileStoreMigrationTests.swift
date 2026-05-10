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

    func testSettingsUIAppStorageChangePersistsManagedSidebarAppearanceToConfig() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              // User comments in cmux.json must survive Settings UI writes.
              "schemaVersion": 1,
              "sidebarAppearance": {
                "matchTerminalBackground": true // Inline comments after literal values must survive.
              }
            }
            """,
            to: primaryURL
        )

        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaultsSuiteName = "cmux.settings-file-store.ui-persist.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            userDefaults: defaults,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertTrue(defaults.bool(forKey: defaultsKey))

        defaults.set(false, forKey: defaultsKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        try waitForSidebarAppearanceMatchTerminalBackground(false, in: primaryURL)
        let updatedContents = try String(contentsOf: primaryURL, encoding: .utf8)
        XCTAssertTrue(updatedContents.contains("User comments in cmux.json must survive Settings UI writes."))
        XCTAssertTrue(updatedContents.contains("Inline comments after literal values must survive."))

        withExtendedLifetime(store) {}
    }

    func testSettingsUISocketPasswordChangePersistsManagedAutomationPasswordToConfig() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "automation": {
                "socketPassword": "old-secret"
              }
            }
            """,
            to: primaryURL
        )

        var storedPassword: String?
        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            loadSocketPassword: { storedPassword },
            saveSocketPassword: { storedPassword = $0 },
            clearSocketPassword: { storedPassword = nil },
            startWatching: true
        )
        XCTAssertEqual(storedPassword, "old-secret")

        storedPassword = "new-secret"
        notificationCenter.post(name: SocketControlPasswordStore.didChangeNotification, object: nil)
        try waitForAutomationSocketPassword("new-secret", in: primaryURL)

        storedPassword = nil
        notificationCenter.post(name: SocketControlPasswordStore.didChangeNotification, object: nil)
        try waitForAutomationSocketPassword(nil, in: primaryURL)

        withExtendedLifetime(store) {}
    }

    func testSettingsUIChangeInsertsIntoSectionWithTrailingComma() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebarAppearance": {
                "tintColor": "#000000",
              }
            }
            """,
            to: primaryURL
        )

        let defaultsKey = "sidebarMatchTerminalBackground"
        let defaultsSuiteName = "cmux.settings-file-store.trailing-comma.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            userDefaults: defaults,
            notificationCenter: notificationCenter,
            startWatching: true
        )

        defaults.set(true, forKey: defaultsKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        try waitForSidebarAppearanceMatchTerminalBackground(true, in: primaryURL)

        withExtendedLifetime(store) {}
    }

    func testUnsupportedManagedCollectionReappliesInsteadOfDrifting() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "browser": {
                "hostsToOpenInEmbeddedBrowser": [
                  "managed.example"
                ]
              }
            }
            """,
            to: primaryURL
        )

        let defaultsKey = BrowserLinkOpenSettings.browserHostWhitelistKey
        let defaultsSuiteName = "cmux.settings-file-store.unsupported-reapply.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: nil,
            userDefaults: defaults,
            notificationCenter: notificationCenter,
            startWatching: true
        )
        XCTAssertEqual(defaults.string(forKey: defaultsKey), "managed.example")

        defaults.set("local.example", forKey: defaultsKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
        try waitForDefaultString("managed.example", key: defaultsKey, defaults: defaults)

        withExtendedLifetime(store) {}
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForSidebarAppearanceMatchTerminalBackground(_ expectedValue: Bool, in url: URL) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sanitized = try JSONCParser.preprocess(data: Data(contentsOf: url))
            if let root = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
               let sidebarAppearance = root["sidebarAppearance"] as? [String: Any],
               sidebarAppearance["matchTerminalBackground"] as? Bool == expectedValue {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for sidebarAppearance.matchTerminalBackground to persist")
    }

    private func waitForAutomationSocketPassword(_ expectedValue: String?, in url: URL) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sanitized = try JSONCParser.preprocess(data: Data(contentsOf: url))
            if let root = try JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
               let automation = root["automation"] as? [String: Any] {
                let actual = automation["socketPassword"]
                if let expectedValue, actual as? String == expectedValue {
                    return
                }
                if expectedValue == nil, actual is NSNull {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for automation.socketPassword to persist")
    }

    private func waitForDefaultString(_ expectedValue: String, key: String, defaults: UserDefaults) throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if defaults.string(forKey: key) == expectedValue {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for \(key) to reapply")
    }
}
