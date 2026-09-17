import AppKit
import CmuxFoundation
import Foundation
import Testing
import struct CmuxSettings.NotificationsCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Keyboard shortcut modifier-hold settings file", .serialized)
struct KeyboardShortcutModifierHoldHintsSettingsFileTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesShowModifierHoldHintsSetting() throws {
        let defaults = UserDefaults.standard
        let key = ShortcutHintDebugSettings.showModifierHoldHintsKey
        try preservingDefaults(keys: [key, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "shortcuts": {
                "showModifierHoldHints": false,
                "openBrowser": "cmd+3"
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.object(forKey: key) as? Bool == false)
            #expect(!ShortcutHintDebugSettings(defaults: defaults).modifierHoldHintsEnabled)
            #expect(store.override(for: .openBrowser) == StoredShortcut(key: "3", command: true, shift: false, option: false, control: false))
        }
    }

    @Test
    func settingsFileStoreAppliesPaneChromeColorSettings() throws {
        let defaults = UserDefaults.standard
        let paneBorderKey = PaneChromeSettings.paneBorderColorKey
        let activePaneBorderKey = PaneChromeSettings.activePaneBorderColorKey
        #expect(paneBorderKey == "paneBorderColor")
        #expect(activePaneBorderKey == "activePaneBorderColor")
        try preservingDefaults(keys: [
            paneBorderKey,
            activePaneBorderKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.set("#112233", forKey: activePaneBorderKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "paneBorderColor": "33aaff",
              "activePaneBorderColor": null
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.string(forKey: paneBorderKey) == "#33AAFF")
            #expect(defaults.object(forKey: activePaneBorderKey) == nil)
        }
    }

    @Test
    func malformedPaneFlashColorDoesNotSkipLaterNotificationSettings() throws {
        let defaults = UserDefaults.standard
        let notifications = NotificationsCatalogSection()
        let paneFlashColorKey = notifications.paneFlashColorHex.userDefaultsKey
        let agentTurnCompleteKey = notifications.agentTurnComplete.userDefaultsKey
        try preservingDefaults(keys: [
            paneFlashColorKey,
            agentTurnCompleteKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.set("never", forKey: agentTurnCompleteKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "notifications": {
                "paneFlashColor": "not-a-color",
                "agentTurnComplete": "always"
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.string(forKey: agentTurnCompleteKey) == "always")
        }
    }

    @Test
    func malformedNotificationSoundDoesNotSkipPaneFlashColor() throws {
        let defaults = UserDefaults.standard
        let paneFlashColorKey = NotificationsCatalogSection().paneFlashColorHex.userDefaultsKey
        try preservingDefaults(keys: [
            NotificationSoundSettings.key,
            paneFlashColorKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.set("#112233", forKey: paneFlashColorKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "notifications": {
                "sound": "not-a-system-sound",
                "paneFlashColor": "#ff69b4"
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.string(forKey: paneFlashColorKey) == "#FF69B4")
        }
    }

    @Test @MainActor
    func focusControllerSeedsBonsplitHintEligibilityFromDisabledSetting() throws {
        let defaults = UserDefaults.standard
        let key = ShortcutHintDebugSettings.showModifierHoldHintsKey
        try preservingDefaults(keys: [key]) {
            defaults.set(false, forKey: key)

            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = manager.addWorkspace(select: true)
            workspace.bonsplitController.tabShortcutHintsEnabled = true

            _ = MainWindowFocusController(
                windowId: UUID(),
                window: nil,
                tabManager: manager,
                fileExplorerState: FileExplorerState()
            )

            #expect(!workspace.bonsplitController.tabShortcutHintsEnabled)
        }
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-file-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Pane attention color")
struct PaneAttentionColorTests {
    @Test
    func fallsBackToSystemBlueWhenUnset() {
        #expect(
            WorkspaceAttentionColor(configuredHex: nil).nsColor.hexString() ==
                NSColor.systemBlue.hexString()
        )
    }

    @Test
    func usesConfiguredHex() {
        #expect(
            WorkspaceAttentionColor(configuredHex: "#ff69b4").nsColor.hexString() == "#FF69B4"
        )
    }

    @Test(arguments: ["not-a-color", "#FFZZZZ", "FF69B4", "#FF69B4AA"])
    func rejectsValuesOutsideSchema(configuredHex: String) {
        #expect(
            WorkspaceAttentionColor(configuredHex: configuredHex).nsColor.hexString() ==
                NSColor.systemBlue.hexString()
        )
    }
}
