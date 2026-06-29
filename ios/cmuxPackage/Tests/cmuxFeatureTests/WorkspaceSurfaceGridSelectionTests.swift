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

        #expect(
            WorkspaceSurfaceGridSelection.terminalIDToOpen(
                in: workspace,
                selectedTerminalID: "terminal-agent"
            ) == "terminal-agent"
        )
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

        #expect(
            WorkspaceSurfaceGridSelection.terminalIDToOpen(
                in: workspace,
                selectedTerminalID: "terminal-from-other-workspace"
            ) == "terminal-build"
        )
    }
}
