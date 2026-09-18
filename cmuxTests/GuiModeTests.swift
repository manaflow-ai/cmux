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
        #expect(AgentSessionPanel.title(provider: .codex, rendererKind: .guiMode, guiModePage: .taskWorktreePR) == "GUI Mode")
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
        let count = manager.tabs.count
        let reopened = try #require(GuiModeWorkspaceCoordinator().createHomeWorkspace(in: manager))
        #expect(reopened.id == workspace.id)
        #expect(manager.tabs.count == count)
        #expect(reopened.focusedPanelId == panel.id)
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
        #expect(
            GuiModeModelCatalog.launchCommand(
                provider: .codex,
                modelID: "gpt-6-astra",
                reasoningEffort: "xhigh",
                permissionMode: "default"
            ) == "codex -a on-request -s workspace-write --model 'gpt-6-astra' -c 'model_reasoning_effort=xhigh'"
        )
        #expect(
            GuiModeModelCatalog.launchCommand(
                provider: .codex,
                modelID: "gpt-6-astra",
                reasoningEffort: "xhigh",
                permissionMode: "auto-review"
            ).contains("--full-auto")
        )
        #expect(
            GuiModeModelCatalog.launchCommand(
                provider: .codex,
                modelID: "gpt-6-astra",
                reasoningEffort: "xhigh",
                permissionMode: "full-access"
            ).contains("--dangerously-bypass-approvals-and-sandbox")
        )
    }

    @Test("GUI state snapshot round trips with task context")
    func snapshotRoundTrip() throws {
        let snapshot = SessionAgentSessionPanelSnapshot(
            rendererKind: .guiMode,
            providerID: .codex,
            workingDirectory: "/tmp/project",
            guiModePage: .taskWorktreePR,
            guiModePrompt: "Build it",
            guiModeProviderID: .qoder,
            guiModeModelID: "default",
            guiModeReasoningEffort: "default"
        )
        let copy = try JSONDecoder().decode(
            SessionAgentSessionPanelSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(copy.rendererKind == .guiMode)
        #expect(copy.guiModePage == .taskWorktreePR)
        #expect(copy.guiModePrompt == "Build it")
        #expect(copy.guiModeProviderID == .qoder)
        #expect(copy.guiModeModelID == "default")
        #expect(copy.guiModeReasoningEffort == "default")
    }
}
