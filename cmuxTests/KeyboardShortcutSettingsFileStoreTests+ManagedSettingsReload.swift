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


// MARK: - Configuration reload and managed defaults restoration
extension KeyboardShortcutSettingsFileStoreTests {
    @MainActor
    func testReloadConfigurationReloadsShortcutSettingsFile() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": "cmd+n"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config")

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    @MainActor
    func testReloadConfigurationMenuActionReloadsRegisteredCmuxConfigStore() throws {
#if DEBUG
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "actions": {
                "first": { "type": "command", "command": "echo first" }
              }
            }
            """,
            to: settingsFileURL
        )

        let tabManager = TabManager()
        let cmuxConfigStore = CmuxConfigStore(
            globalConfigPath: settingsFileURL.path,
            startFileWatchers: false
        )
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()
        XCTAssertNotNil(cmuxConfigStore.resolvedAction(id: "first"))
        XCTAssertNil(cmuxConfigStore.resolvedAction(id: "second"))

        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: cmuxConfigStore
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        let previousMainMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMainMenu }

        let mainMenu = NSMenu(title: "Main")
        let appMenuItem = NSMenuItem(title: "cmux", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "cmux")
        let originalReloadItem = NSMenuItem(
            title: String(localized: "menu.app.reloadConfiguration", defaultValue: "Reload Configuration"),
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        appMenu.addItem(originalReloadItem)
        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)
        NSApp.mainMenu = mainMenu

        let selector = NSSelectorFromString("reloadConfigurationMenuItem:")
        XCTAssertTrue(
            appDelegate.responds(to: selector),
            "Reload Configuration menu item must have an AppKit selector-backed action path"
        )
        appDelegate.installReloadConfigurationMenuItemAction()
        XCTAssertTrue(originalReloadItem.target === appDelegate)
        XCTAssertEqual(originalReloadItem.action, selector)
        XCTAssertEqual(
            originalReloadItem.identifier,
            NSUserInterfaceItemIdentifier("com.cmux.reloadConfiguration")
        )

        let rebuiltReloadItem = NSMenuItem(
            title: originalReloadItem.title,
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        appMenu.removeItem(originalReloadItem)
        appMenu.addItem(rebuiltReloadItem)
        appDelegate.menuNeedsUpdate(appMenu)
        XCTAssertTrue(rebuiltReloadItem.target === appDelegate)
        XCTAssertEqual(rebuiltReloadItem.action, selector)

        try writeSettingsFile(
            """
            {
              "actions": {
                "second": { "type": "command", "command": "echo second" }
              }
            }
            """,
            to: settingsFileURL
        )

        let unrelatedReloadItem = NSMenuItem(
            title: rebuiltReloadItem.title,
            action: NSSelectorFromString("swiftuiPrivateReloadAction:"),
            keyEquivalent: ""
        )
        let unrelatedMenu = NSMenu(title: "Unrelated")
        unrelatedMenu.addItem(unrelatedReloadItem)
        appDelegate.menuNeedsUpdate(unrelatedMenu)
        XCTAssertFalse(unrelatedReloadItem.target === appDelegate)
        XCTAssertNotEqual(unrelatedReloadItem.action, selector)

        XCTAssertTrue(NSApp.sendAction(selector, to: rebuiltReloadItem.target, from: rebuiltReloadItem))

        XCTAssertNil(cmuxConfigStore.resolvedAction(id: "first"))
        XCTAssertNotNil(cmuxConfigStore.resolvedAction(id: "second"))
#else
        throw XCTSkip("menu selector regression requires DEBUG app test helpers")
#endif
    }

    func testManagedUserDefaultSettingRestoresBackedUpValueWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspaceAutoReorderSettings.key
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

        defaults.set(false, forKey: managedKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "app": {
                "reorderOnNotification": true
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, true)

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.object(forKey: managedKey) as? Bool, false)
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    func testSettingsFileStoreAppliesWorkspaceColorDictionaryAndAllowsRemovingDefaults() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Blue": "#2244ff",
                  "Neon Mint": "#00f5d4"
                }
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

        let palette = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(palette.map(\.name), ["Blue", "Neon Mint"])
        XCTAssertEqual(palette.map(\.hex), ["#2244FF", "#00F5D4"])
    }

    func testManagedWorkspaceColorsRestoreLegacyPaletteWhenFileSettingIsRemoved() throws {
        let defaults = UserDefaults.standard
        let previousPalette = defaults.dictionary(forKey: WorkspaceTabColorSettings.paletteKey) as? [String: String]
        let previousLegacyOverrides = defaults.dictionary(forKey: "workspaceTabColor.defaultOverrides") as? [String: String]
        let previousLegacyCustomColors = defaults.array(forKey: "workspaceTabColor.customColors") as? [String]
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            WorkspaceTabColorSettings.reset(defaults: defaults)
            if let previousPalette {
                defaults.set(previousPalette, forKey: WorkspaceTabColorSettings.paletteKey)
            }
            if let previousLegacyOverrides {
                defaults.set(previousLegacyOverrides, forKey: "workspaceTabColor.defaultOverrides")
            }
            if let previousLegacyCustomColors {
                defaults.set(previousLegacyCustomColors, forKey: "workspaceTabColor.customColors")
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        WorkspaceTabColorSettings.reset(defaults: defaults)
        defaults.set(["Blue": "#010203"], forKey: "workspaceTabColor.defaultOverrides")
        defaults.set(["#778899"], forKey: "workspaceTabColor.customColors")
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let managedSettingsURL = directoryURL.appendingPathComponent("managed.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": {
                  "Neon Mint": "#00F5D4"
                }
              }
            }
            """,
            to: managedSettingsURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: managedSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspaceTabColorSettings.palette(defaults: defaults).map(\.name), ["Neon Mint"])

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let restored = WorkspaceTabColorSettings.palette(defaults: defaults)
        XCTAssertEqual(restored.first(where: { $0.name == "Blue" })?.hex, "#010203")
        XCTAssertEqual(restored.first(where: { $0.name == "Custom 1" })?.hex, "#778899")
        XCTAssertNil(defaults.data(forKey: settingsFileBackupsDefaultsKey))
    }

    @MainActor
    func testReloadConfigurationReloadsManagedAppSettingsFromSettingsFile() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
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
                "newWorkspacePlacement": "top"
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(WorkspacePlacementSettings.current(), .top)

        try writeSettingsFile(
            """
            {
              "app": {
                "newWorkspacePlacement": "end"
              }
            }
            """,
            to: settingsFileURL
        )

        GhosttyApp.shared.reloadConfiguration(source: "test.reload_config_app_setting")

        XCTAssertEqual(WorkspacePlacementSettings.current(), .end)
    }

    @MainActor
    func testManagedWorkspacePlacementChangesDefaultInsertionBehavior() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspacePlacementSettings.placementKey
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
                "newWorkspacePlacement": "top"
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

        let manager = TabManager()
        guard let first = manager.tabs.first else {
            XCTFail("Expected initial workspace")
            return
        }

        let second = manager.addWorkspace(placementOverride: .end)
        let third = manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)

        let inserted = manager.addWorkspace()

        XCTAssertEqual(manager.tabs.map(\.id), [inserted.id, first.id, second.id, third.id])
        XCTAssertEqual(manager.selectedTabId, inserted.id)
    }

    func testSettingsFileStoreAppliesWorkspaceGroupNewWorkspacePlacement() throws {
        let defaults = UserDefaults.standard
        let managedKey = WorkspaceGroupNewWorkspacePlacementSettings.key
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
              "workspaceGroups": {
                "newWorkspacePlacement": "end"
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

        XCTAssertEqual(WorkspaceGroupNewWorkspacePlacementSettings.resolved(defaults: defaults), .end)
    }

}
