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
}
