import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Appearance import and managed appearance replay
extension KeyboardShortcutSettingsFileStoreStartupTests {
    func testSettingsFileStoreRestoresAbsentAppIconBackupDuringStartupWithoutTouchingAppKit() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: AppIconSettings.modeKey)
        let previousAppearance = defaults.object(forKey: AppearanceSettings.appearanceModeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        let previousImportedDefaults = defaults.data(forKey: importedManagedDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppIconSettings.modeKey)
            } else {
                defaults.removeObject(forKey: AppIconSettings.modeKey)
            }

            if let previousAppearance {
                defaults.set(previousAppearance, forKey: AppearanceSettings.appearanceModeKey)
            } else {
                defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)
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

        defaults.removeObject(forKey: AppIconSettings.modeKey)
        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
        defaults.removeObject(forKey: importedManagedDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedIconURL = directoryURL.appendingPathComponent("icon.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: managedIconURL
        )

        var startObservationCallCount = 0
        var stopObservationCallCount = 0
        var imageRequestCount = 0
        var runtimeIconSetCount = 0
        var dockTileNotificationCount = 0
        AppIconSettings.setLiveEnvironmentProviderForTesting {
            AppIconSettings.Environment(
                isApplicationFinishedLaunching: { false },
                imageForMode: { _ in
                    imageRequestCount += 1
                    return nil
                },
                setApplicationIconImage: { _ in
                    runtimeIconSetCount += 1
                },
                startAppearanceObservation: {
                    startObservationCallCount += 1
                },
                stopAppearanceObservation: {
                    stopObservationCallCount += 1
                },
                notifyDockTilePlugin: {
                    dockTileNotificationCount += 1
                }
            )
        }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedIconURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: AppIconSettings.modeKey), AppIconMode.automatic.rawValue)

        let managedAppearanceURL = directoryURL.appendingPathComponent("appearance.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appearance": "system"
              }
            }
            """,
            to: managedAppearanceURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedAppearanceURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: AppIconSettings.modeKey))
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
    }

    func testManagedAppearanceReplayUpdatesDefaultWithoutLiveAppearanceApplication() throws {
        let defaults = UserDefaults.standard
        let key = AppearanceSettings.appearanceModeKey

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
                    "appearance": "dark"
                  }
                }
                """,
                to: settingsFileURL
            )

            var appliedAppearanceNames: [NSAppearance.Name?] = []
            var synchronizedAppearanceNames: [(appearance: NSAppearance.Name?, source: String)] = []
            AppearanceSettings.setLiveEnvironmentProviderForTesting {
                AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { appearance in
                        appliedAppearanceNames.append(appearance?.bestMatch(from: [.darkAqua, .aqua]))
                    },
                    synchronizeTerminalThemeWithAppearance: { appearance, source in
                        synchronizedAppearanceNames.append((
                            appearance: appearance?.bestMatch(from: [.darkAqua, .aqua]),
                            source: source
                        ))
                    },
                    systemAppearance: {
                        NSAppearance(named: .aqua)
                    }
                )
            }

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.dark.rawValue)
            XCTAssertTrue(appliedAppearanceNames.isEmpty)
            XCTAssertTrue(synchronizedAppearanceNames.isEmpty)

            store.applyDeferredManagedDefaultSideEffects()

            XCTAssertTrue(appliedAppearanceNames.isEmpty)
            XCTAssertTrue(synchronizedAppearanceNames.isEmpty)

            try withExtendedLifetime(store) {
                try writeSettingsFile(
                    """
                    {
                      "app": {
                        "appearance": "light"
                      }
                    }
                    """,
                    to: settingsFileURL
                )
                store.reload()
            }

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.light.rawValue)
            XCTAssertTrue(appliedAppearanceNames.isEmpty)
            XCTAssertTrue(synchronizedAppearanceNames.isEmpty)
        }
    }

    func testSettingsFileStoreDoesNotReachTerminalReloadThroughManagedAppearanceReplay() throws {
        let defaults = UserDefaults.standard
        let key = AppearanceSettings.appearanceModeKey

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
                    "appearance": "dark"
                  }
                }
                """,
                to: settingsFileURL
            )

            var storeInitInProgress = true
            var reachedTerminalReloadDuringInit = false
            var terminalReloadSources: [String] = []
            AppearanceSettings.setLiveEnvironmentProviderForTesting {
                AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { _ in },
                    synchronizeTerminalThemeWithAppearance: { _, source in
                        if storeInitInProgress {
                            reachedTerminalReloadDuringInit = true
                        }
                        terminalReloadSources.append(source)
                    },
                    systemAppearance: {
                        NSAppearance(named: .aqua)
                    }
                )
            }

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )
            storeInitInProgress = false

            XCTAssertFalse(reachedTerminalReloadDuringInit)
            XCTAssertTrue(terminalReloadSources.isEmpty)

            try writeSettingsFile(
                """
                {
                  "app": {
                    "appearance": "light"
                  }
                }
                """,
                to: settingsFileURL
            )
            store.reload()

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.light.rawValue)
            XCTAssertTrue(
                terminalReloadSources.isEmpty,
                "CmuxSettingsFileStore must not synchronously route managed appearance replay into Ghostty reloadConfiguration"
            )
        }
    }

    func testManagedAppearanceUserDefaultSurvivesSettingsFileReapplyUntilFileChanges() throws {
        let defaults = UserDefaults.standard
        let key = AppearanceSettings.appearanceModeKey

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
                    "appearance": "system"
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

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.system.rawValue)

            defaults.set(AppearanceMode.light.rawValue, forKey: key)
            try withExtendedLifetime(store) {
                notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
                XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.light.rawValue)

                let relaunchedStore = KeyboardShortcutSettingsFileStore(
                    primaryPath: settingsFileURL.path,
                    fallbackPath: nil,
                    additionalFallbackPaths: [],
                    startWatching: false
                )
                XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.light.rawValue)

                try writeSettingsFile(
                    """
                    {
                      "app": {
                        "appearance": "dark"
                      }
                    }
                    """,
                    to: settingsFileURL
                )
                relaunchedStore.reload()
                XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.dark.rawValue)
            }
        }
    }

    @MainActor
    func testSettingsFileStoreInitialAppearanceImportDoesNotApplyLiveAppearance() throws {
        let defaults = UserDefaults.standard
        let key = AppearanceSettings.appearanceModeKey

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
                    "appearance": "dark"
                  }
                }
                """,
                to: settingsFileURL
            )

            var appliedAppearanceName: NSAppearance.Name?
            var synchronizedAppearanceName: NSAppearance.Name?
            var synchronizedSources: [String] = []
            AppearanceSettings.setLiveEnvironmentProviderForTesting {
                AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { appearance in
                        appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                    },
                    synchronizeTerminalThemeWithAppearance: { appearance, source in
                        synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                        synchronizedSources.append(source)
                    },
                    systemAppearance: {
                        NSAppearance(named: .aqua)
                    }
                )
            }

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.dark.rawValue)
            XCTAssertNil(appliedAppearanceName)
            XCTAssertNil(synchronizedAppearanceName)
            XCTAssertTrue(synchronizedSources.isEmpty)

            store.applyDeferredManagedDefaultSideEffects()

            XCTAssertNil(appliedAppearanceName)
            XCTAssertNil(synchronizedAppearanceName)
            XCTAssertTrue(synchronizedSources.isEmpty)

            try writeSettingsFile(
                """
                {
                  "app": {
                    "appearance": "light"
                  }
                }
                """,
                to: settingsFileURL
            )
            store.reload()

            XCTAssertEqual(defaults.string(forKey: key), AppearanceMode.light.rawValue)
            XCTAssertNil(appliedAppearanceName)
            XCTAssertNil(synchronizedAppearanceName)
            XCTAssertTrue(synchronizedSources.isEmpty)
        }
    }

}
