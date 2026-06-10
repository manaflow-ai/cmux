import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Managed app settings application
extension KeyboardShortcutSettingsFileStoreTests {
    func testSettingsFileStoreAppliesSubagentNotificationSuppression() throws {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
            } else {
                defaults.removeObject(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "automation": {
                "suppressSubagentNotifications": false
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

        XCTAssertEqual(
            defaults.object(forKey: AgentSubagentNotificationSettings.suppressNotificationsKey) as? Bool,
            false
        )
    }

    func testSettingsFileStoreInvalidKiroNotificationLevelDoesNotSkipLaterAutomationKeys() throws {
        let defaults = UserDefaults.standard
        let previousKiroLevel = defaults.object(forKey: KiroIntegrationSettings.notificationLevelKey)
        let previousPortBase = defaults.object(forKey: AutomationSettings.portBaseKey)
        let previousPortRange = defaults.object(forKey: AutomationSettings.portRangeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousKiroLevel {
                defaults.set(previousKiroLevel, forKey: KiroIntegrationSettings.notificationLevelKey)
            } else {
                defaults.removeObject(forKey: KiroIntegrationSettings.notificationLevelKey)
            }
            if let previousPortBase {
                defaults.set(previousPortBase, forKey: AutomationSettings.portBaseKey)
            } else {
                defaults.removeObject(forKey: AutomationSettings.portBaseKey)
            }
            if let previousPortRange {
                defaults.set(previousPortRange, forKey: AutomationSettings.portRangeKey)
            } else {
                defaults.removeObject(forKey: AutomationSettings.portRangeKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: KiroIntegrationSettings.notificationLevelKey)
        defaults.removeObject(forKey: AutomationSettings.portBaseKey)
        defaults.removeObject(forKey: AutomationSettings.portRangeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "automation": {
                "kiroNotificationLevel": "loud",
                "portBase": 32100,
                "portRange": 42
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

        XCTAssertNil(defaults.object(forKey: KiroIntegrationSettings.notificationLevelKey))
        XCTAssertEqual(defaults.integer(forKey: AutomationSettings.portBaseKey), 32100)
        XCTAssertEqual(defaults.integer(forKey: AutomationSettings.portRangeKey), 42)
    }

    func testSettingsFileStoreAppliesBrowserHiddenWebViewDiscardDelayAtMaximum() throws {
        let defaults = UserDefaults.standard
        let previousEnabled = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        let previousDelay = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousEnabled {
                defaults.set(previousEnabled, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
            }
            if let previousDelay {
                defaults.set(previousDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "browser": {
                "discardHiddenWebViews": false,
                "hiddenWebViewDiscardDelaySeconds": 3600
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

        XCTAssertEqual(
            defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey) as? Bool,
            false
        )
        XCTAssertEqual(
            defaults.double(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey),
            BrowserHiddenWebViewDiscardPolicy.maximumHiddenDelay
        )
    }

    func testSettingsFileStoreIgnoresBrowserHiddenWebViewDiscardDelayAboveMaximum() throws {
        let defaults = UserDefaults.standard
        let previousDelay = defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousDelay {
                defaults.set(previousDelay, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            } else {
                defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }
        defaults.removeObject(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "browser": {
                "hiddenWebViewDiscardDelaySeconds": 3601
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

        XCTAssertNil(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey))
    }

    func testSettingsFileStoreParsesWorkspaceWorkingDirectoryInheritanceSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspaceWorkingDirectoryInheritanceSettings.key
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "workspaceInheritWorkingDirectory": false
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

        XCTAssertFalse(WorkspaceWorkingDirectoryInheritanceSettings.isEnabled())
    }

    func testInvalidForkConversationDefaultDoesNotAbortRemainingAppSettings() throws {
        let defaults = UserDefaults.standard
        let forkKey = AgentConversationForkDefaultSettings.key
        let inheritanceKey = WorkspaceWorkingDirectoryInheritanceSettings.key
        let previousForkValue = defaults.object(forKey: forkKey)
        let previousInheritanceValue = defaults.object(forKey: inheritanceKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousForkValue {
                defaults.set(previousForkValue, forKey: forkKey)
            } else {
                defaults.removeObject(forKey: forkKey)
            }
            if let previousInheritanceValue {
                defaults.set(previousInheritanceValue, forKey: inheritanceKey)
            } else {
                defaults.removeObject(forKey: inheritanceKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: forkKey)
        defaults.removeObject(forKey: inheritanceKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "forkConversationDefaultDestination": "sideways",
                "workspaceInheritWorkingDirectory": false
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

        XCTAssertEqual(AgentConversationForkDefaultSettings.current(), .right)
        XCTAssertFalse(WorkspaceWorkingDirectoryInheritanceSettings.isEnabled())
    }

    func testSettingsFileStoreParsesSidebarWorkspaceTitleWrapSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = SidebarWorkspaceTitleWrapSettings.key
        let previousValue = defaults.object(forKey: managedKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: managedKey)
            } else {
                defaults.removeObject(forKey: managedKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "sidebar": {
                "wrapWorkspaceTitles": true
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

        XCTAssertTrue(SidebarWorkspaceTitleWrapSettings.wraps(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: SidebarWorkspaceTitleWrapSettings.key) as? Bool, true)
    }

    func testSettingsFileStoreDoesNotApplyAutomaticAppIconDuringStartupReplay() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: AppIconSettings.modeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppIconSettings.modeKey)
            } else {
                defaults.removeObject(forKey: AppIconSettings.modeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: AppIconSettings.modeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
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
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: AppIconSettings.modeKey), AppIconMode.automatic.rawValue)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
    }

    func testSettingsFileStoreCanReplayAutomaticAppIconSettingTwiceWithoutTouchingAppKit() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: AppIconSettings.modeKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: AppIconSettings.modeKey)
            } else {
                defaults.removeObject(forKey: AppIconSettings.modeKey)
            }

            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: AppIconSettings.modeKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "appIcon": "automatic"
              }
            }
            """,
            to: settingsFileURL
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
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: AppIconSettings.modeKey), AppIconMode.automatic.rawValue)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
    }

}
