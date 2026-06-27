import CmuxFoundation
import Foundation
import Testing

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
                fileExplorerState: FileExplorerState(),
                surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
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
