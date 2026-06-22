import Foundation
import Testing
import CmuxCommandPalette
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias AppStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias AppStoredShortcut = cmux.StoredShortcut
#endif

@Suite struct OpenChatShortcutSettingsTests {
    @Test func defaultsToCmdJAndIsUserEditable() {
        let cmdJ = AppStoredShortcut(key: "j", command: true, shift: false, option: false, control: false)
        let settingsCmdJ = CmuxSettings.StoredShortcut(first: CmuxSettings.ShortcutStroke(key: "j", command: true))
        let cmdShiftJ = AppStoredShortcut(key: "j", command: true, shift: true, option: false, control: false)
        let settingsCmdShiftJ = CmuxSettings.StoredShortcut(first: CmuxSettings.ShortcutStroke(key: "j", command: true, shift: true))

        #expect(KeyboardShortcutSettings.shortcut(for: .openChat) == cmdJ)
        #expect(ShortcutAction.openChat.defaultShortcut == settingsCmdJ)
        #expect(KeyboardShortcutSettings.shortcut(for: .openChatWorkspace) == cmdShiftJ)
        #expect(ShortcutAction.openChatWorkspace.defaultShortcut == settingsCmdShiftJ)
        #expect(
            KeyboardShortcutSettings.Action.openChat.normalizedRecordedShortcutResult(cmdJ) == .accepted(cmdJ),
            "Default Open Chat shortcut must not conflict with any other action"
        )
        #expect(
            KeyboardShortcutSettings.Action.openChatWorkspace.normalizedRecordedShortcutResult(cmdShiftJ) == .accepted(cmdShiftJ),
            "Default Open Chat workspace shortcut must not conflict with any other action"
        )
        #expect(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openChat),
            "Open Chat must be visible/editable in Settings > Keyboard Shortcuts"
        )
        #expect(
            KeyboardShortcutSettings.settingsVisibleActions.contains(.openChatWorkspace),
            "Open Chat workspace must be visible/editable in Settings > Keyboard Shortcuts"
        )
    }
}

@Suite struct OpenChatCommandPaletteTests {
    @Test func openChatQuerySurfacesOpenChatCommand() {
        let corpus = [
            CommandPaletteSearchCorpusEntry(
                payload: "palette.openDiffViewer",
                rank: 0,
                title: "Open Diff Viewer",
                searchableTexts: ["Open Diff Viewer", "Workspace", "diff", "changes", "git", "review", "branch"]
            ),
            CommandPaletteSearchCorpusEntry(
                payload: "palette.openChat",
                rank: 1,
                title: "Open Chat",
                searchableTexts: ["Open Chat", "Workspace"] + ContentView.commandPaletteOpenChatKeywords
            ),
        ]

        let results = CommandPaletteSearchEngine(entries: corpus).search(query: "open chat", resultLimit: 5) { _, _ in 0 }

        #expect(results.first?.payload == "palette.openChat")
    }
}

@Suite struct OpenChatConfigTests {
    private func decode(_ json: String) throws -> CmuxConfigFile {
        try JSONDecoder().decode(CmuxConfigFile.self, from: Data(json.utf8))
    }

    @Test func legacySurfaceTabBarButtonsCanIncludeOpenChat() throws {
        let config = try decode("""
        {
          "surfaceTabBarButtons": ["newTerminal", "openChat", "splitRight"],
          "commands": []
        }
        """)

        #expect(config.surfaceTabBarButtons == [.newTerminal, .openChat, .splitRight])
    }

    @Test func defaultSurfaceTabBarButtonsIncludeOpenChat() {
        #expect(
            CmuxSurfaceTabBarButton.defaults.map(\.id) == [
                CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
                CmuxSurfaceTabBarBuiltInAction.openChat.configID,
                CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
                CmuxSurfaceTabBarBuiltInAction.splitRight.configID,
                CmuxSurfaceTabBarBuiltInAction.splitDown.configID,
            ]
        )
    }
}

@Suite struct OpenChatModelOptionsTests {
    @Test func includesDirectAndOpenCodeBackedModels() {
        let options = OpenChatModelOptionCatalog(defaultModelLabel: "Default").options()
        let byId = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })

        #expect(byId["claude:default"]?.backendProviderID == "claude")
        #expect(byId["codex:gpt-5.5"]?.backendProviderID == "codex")
        #expect(byId["opencode:default"]?.backendProviderID == "opencode")
        #expect(byId["opencode:anthropic/claude-sonnet-4-5"]?.openCodeProviderID == "anthropic")
        #expect(byId["opencode:openai/gpt-5.5"]?.openCodeProviderID == "openai")
        #expect(byId["opencode:google/gemini-2.5-pro"]?.openCodeProviderID == "google")
        #expect(byId["opencode:xai/grok-4"]?.openCodeProviderID == "xai")
        #expect(options.filter(\.isSelected).map(\.id) == ["codex:gpt-5.5"])
    }
}
