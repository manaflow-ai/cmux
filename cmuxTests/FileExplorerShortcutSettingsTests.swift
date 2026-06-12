import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct FileExplorerShortcutSettingsTests {
    @Test func openSelectionShortcutsAreSidebarFocusedAndSettingsBacked() throws {
        let primary = KeyboardShortcutSettings.Action.fileExplorerOpenSelection
        let finderAlias = KeyboardShortcutSettings.Action.fileExplorerOpenSelectionFinderAlias
        let primaryDefault = primary.defaultShortcut
        let finderAliasDefault = finderAlias.defaultShortcut

        #expect(primaryDefault.key == "\r")
        #expect(!primaryDefault.command)
        #expect(!primaryDefault.shift)
        #expect(!primaryDefault.option)
        #expect(!primaryDefault.control)
        #expect(finderAliasDefault.key == "↓")
        #expect(finderAliasDefault.command)
        #expect(!finderAliasDefault.shift)
        #expect(!finderAliasDefault.option)
        #expect(!finderAliasDefault.control)
        #expect(primary.allowsBareFirstStroke)
        #expect(finderAlias.allowsBareFirstStroke)
        #expect(!primary.allowsChordShortcut)
        #expect(!finderAlias.allowsChordShortcut)
        #expect(primary.shortcutContext == .rightSidebarFocus)
        #expect(finderAlias.shortcutContext == .rightSidebarFocus)

        let settingsPrimary = try #require(ShortcutAction(rawValue: primary.rawValue))
        let settingsFinderAlias = try #require(ShortcutAction(rawValue: finderAlias.rawValue))

        #expect(settingsPrimary.defaultStroke == CmuxSettings.ShortcutStroke(key: "\r"))
        #expect(settingsFinderAlias.defaultStroke == CmuxSettings.ShortcutStroke(key: "↓", command: true))
        #expect(settingsPrimary.displayName == primary.label)
        #expect(settingsFinderAlias.displayName == finderAlias.label)
    }

    @Test func openSelectionShortcutsStayOutOfAppWideBareStartCache() throws {
        try withIsolatedShortcutSettings {
            #expect(!KeyboardShortcutBareStartCache.hasConfiguredBareShortcutStart(key: "\r"))

            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "↓", command: false, shift: false, option: false, control: false),
                for: .fileExplorerOpenSelection
            )

            #expect(!KeyboardShortcutBareStartCache.hasConfiguredBareShortcutStart(key: "↓"))
        }
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-explorer-shortcut-settings"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }

        try body()
    }
}
