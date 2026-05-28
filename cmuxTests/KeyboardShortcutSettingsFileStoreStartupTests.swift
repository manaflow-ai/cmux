import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class KeyboardShortcutSettingsFileStoreStartupTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        AppearanceSettings.resetLiveEnvironmentProviderForTesting()
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-startup-\(UUID().uuidString)",
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

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }
        try body()
    }
}
