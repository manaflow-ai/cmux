import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("GUI Mode")
struct GuiModeTests {
    @Test("default tab bar places GUI Mode after terminal and browser")
    func defaultButtonOrder() {
        #expect(CmuxSurfaceTabBarButton.defaults.map(\.id) == [
            CmuxSurfaceTabBarBuiltInAction.newTerminal.configID,
            CmuxSurfaceTabBarBuiltInAction.newBrowser.configID,
            CmuxSurfaceTabBarBuiltInAction.newGuiMode.configID,
            CmuxSurfaceTabBarBuiltInAction.splitRight.configID,
            CmuxSurfaceTabBarBuiltInAction.splitDown.configID,
        ])
        #expect(CmuxSurfaceTabBarBuiltInAction(configID: "gui-mode") == .newGuiMode)
    }

    @Test("GUI shortcut is mnemonic and does not reuse the G action family")
    func shortcutDefaultAndCatalog() {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .newGuiMode)
        #expect(shortcut.key == "g")
        #expect(shortcut.command && shortcut.option && shortcut.shift && !shortcut.control)
        #expect(KeyboardShortcutSettings.Action.allCases.filter {
            KeyboardShortcutSettings.shortcut(for: $0) == shortcut
        } == [.newGuiMode])
        #expect(CmuxSettings.ShortcutAction.newGuiMode.defaultShortcut?.displayString == shortcut.displayString)
    }

    @Test("button and command palette share the GUI workspace coordinator")
    @MainActor
    func coordinatorCreatesGuiPanel() throws {
        let manager = TabManager()
        let workspace = try #require(GuiModeWorkspaceCoordinator().createHomeWorkspace(in: manager))
        let panel = try #require(workspace.panels.values.compactMap { $0 as? AgentSessionPanel }.first)
        #expect(panel.rendererKind == .guiMode)
        #expect(panel.guiModeState == .home)
        #expect(manager.selectedTabId == workspace.id)
    }

    @Test("command palette exposes the configurable GUI shortcut")
    func commandPaletteContribution() throws {
        let contribution = try #require(
            ContentView.commandPaletteGuiModeContributions().first
        )
        #expect(contribution.commandId == GuiModeWorkspaceCoordinator.commandPaletteCommandId)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: contribution.commandId) == .newGuiMode)
        #expect(contribution.keywords.contains("gui"))
    }

    @Test("task command quoting preserves shell metacharacters")
    func taskCommandQuoting() {
        #expect(
            GuiModeWorkspaceCoordinator.taskWorktreePRCommand(
                prompt: "Build $HOME's `thing`",
                providerID: .claude
            ) == "/task-worktree-pr --provider claude 'Build $HOME'\\''s `thing`'"
        )
        #expect(GuiModeWorkspaceCoordinator.taskWorktreePRInput(prompt: "Build it", providerID: .codex).hasSuffix("\n"))
        #expect(GuiModeWorkspaceCoordinator.taskWorkspaceTitle(prompt: "  build\n\tthe   UI  ") == "GUI: build the UI")
    }

    @Test("GUI state snapshot round trips with task context")
    func snapshotRoundTrip() throws {
        let snapshot = SessionAgentSessionPanelSnapshot(
            rendererKind: .guiMode,
            providerID: .codex,
            workingDirectory: "/tmp/project",
            guiModePage: .taskWorktreePR,
            guiModePrompt: "Build it",
            guiModeProviderID: .qoder
        )
        let copy = try JSONDecoder().decode(
            SessionAgentSessionPanelSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(copy.rendererKind == .guiMode)
        #expect(copy.guiModePage == .taskWorktreePR)
        #expect(copy.guiModePrompt == "Build it")
        #expect(copy.guiModeProviderID == .qoder)
    }
}
