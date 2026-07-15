import Testing
import CmuxMobileShellModel
@testable import CmuxMobileShellUI

@Suite struct WorkspaceSurfaceGridSelectionTests {
    @Test func usesSelectedTerminalWhenItBelongsToWorkspace() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-build",
            name: "Build",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        )

        let selection = WorkspaceSurfaceGridSelection(
            workspace: workspace,
            selectedTerminalID: "terminal-agent"
        )

        #expect(selection.terminalIDToOpen() == "terminal-agent")
    }

    @Test func fallsBackToFirstTerminalWhenSelectionBelongsToAnotherWorkspace() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-build",
            name: "Build",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        )

        let selection = WorkspaceSurfaceGridSelection(
            workspace: workspace,
            selectedTerminalID: "terminal-from-other-workspace"
        )

        #expect(selection.terminalIDToOpen() == "terminal-build")
    }

    @Test func returnsNilWhenWorkspaceHasNoTerminals() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-empty",
            name: "Empty",
            terminals: []
        )

        let selection = WorkspaceSurfaceGridSelection(
            workspace: workspace,
            selectedTerminalID: "terminal-from-other-workspace"
        )

        #expect(selection.terminalIDToOpen() == nil)
    }
}
