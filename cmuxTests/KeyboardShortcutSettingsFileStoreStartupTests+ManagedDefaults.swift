import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Managed user-default survival and initial import
extension KeyboardShortcutSettingsFileStoreStartupTests {
    func testSidebarMatchTerminalBackgroundUserDefaultSurvivesSettingsFileReapply() throws {
        let defaults = UserDefaults.standard
        let key = SidebarMatchTerminalBackgroundSettings.userDefaultsKey
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
              "sidebarAppearance": {
                "matchTerminalBackground": true
              }
            }
            """,
            to: settingsFileURL
        )

        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: true
        )

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)

        defaults.set(false, forKey: key)
        try withExtendedLifetime(store) {
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

            _ = KeyboardShortcutSettingsFileStore(primaryPath: settingsFileURL.path, fallbackPath: nil, additionalFallbackPaths: [], startWatching: false)
            XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

            try writeSettingsFile(
                """
                {
                  "sidebarAppearance": {
                    "matchTerminalBackground": false
                  }
                }
                """,
                to: settingsFileURL
            )
            store.reload()
            XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

            defaults.set(true, forKey: key)
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        }
    }

    func testManagedBoolUserDefaultSurvivesSettingsFileReapplyUntilFileChanges() throws {
        let defaults = UserDefaults.standard
        let key = QuitWarningSettings.warnBeforeQuitKey

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
                    "warnBeforeQuit": true
                  }
                }
                """,
                to: settingsFileURL
            )

            let notificationCenter = NotificationCenter()
            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                notificationCenter: notificationCenter,
                startWatching: true
            )

            XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)

            defaults.set(false, forKey: key)
            try withExtendedLifetime(store) {
                notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
                XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

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
                defaults.set(true, forKey: key)
                XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)

                store.reload()
                XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)

                defaults.set(true, forKey: key)
                notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
                XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
            }
        }
    }

    @MainActor
    func testInitialSettingsFileLoadImportsDefaultsWithoutLiveDefaultNotifications() throws {
        let defaults = UserDefaults.standard
        let scrollBarKey = TerminalScrollBarSettings.showScrollBarKey
        let autoResumeKey = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey

        try preservingDefaults(keys: [
            scrollBarKey,
            autoResumeKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: scrollBarKey)
            defaults.removeObject(forKey: autoResumeKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "terminal": {
                    "showScrollBar": false,
                    "autoResumeAgentSessions": false
                  }
                }
                """,
                to: settingsFileURL
            )

            let notificationCenter = NotificationCenter()
            var scrollBarNotificationCount = 0
            var autoResumeNotificationCount = 0
            let scrollBarObserver = notificationCenter.addObserver(
                forName: TerminalScrollBarSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                scrollBarNotificationCount += 1
            }
            let autoResumeObserver = notificationCenter.addObserver(
                forName: AgentSessionAutoResumeSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                autoResumeNotificationCount += 1
            }
            defer {
                notificationCenter.removeObserver(scrollBarObserver)
                notificationCenter.removeObserver(autoResumeObserver)
            }

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                notificationCenter: notificationCenter,
                startWatching: false
            )

            XCTAssertEqual(defaults.object(forKey: scrollBarKey) as? Bool, false)
            XCTAssertEqual(defaults.object(forKey: autoResumeKey) as? Bool, false)
            XCTAssertEqual(scrollBarNotificationCount, 0)
            XCTAssertEqual(autoResumeNotificationCount, 0)

            store.applyDeferredManagedDefaultSideEffects()

            XCTAssertEqual(scrollBarNotificationCount, 1)
            XCTAssertEqual(autoResumeNotificationCount, 1)
        }
    }

}
