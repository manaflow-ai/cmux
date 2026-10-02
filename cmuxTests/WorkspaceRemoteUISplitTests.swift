import Bonsplit
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceRemoteUISplitTests {
#if DEBUG
    @Test(arguments: [false, true])
    func splitButtonStartsAndTracksRemoteTerminal(persistent: Bool) throws {
        let workspace = remoteWorkspace(persistent: persistent)
        defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let sourcePane = try #require(controller.focusedPaneId)
        let newPane = try #require(controller.splitPane(sourcePane, orientation: .horizontal))
        let newTab = try #require(controller.selectedTab(inPane: newPane))
        let panelID = try #require(workspace.panelIdFromSurfaceId(newTab.id))

        try expectRemoteTerminal(panelID, in: workspace, persistent: persistent)
    }

    @Test(arguments: [false, true])
    func draggingOnlyTabReplacesPlaceholderWithRemoteTerminal(persistent: Bool) throws {
        let workspace = remoteWorkspace(persistent: persistent)
        defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let sourcePane = try #require(controller.focusedPaneId)
        let sourceTab = try #require(controller.selectedTab(inPane: sourcePane))
        let movedPane = try #require(controller.splitPane(
            sourcePane,
            orientation: .vertical,
            movingTab: sourceTab.id,
            insertFirst: false
        ))
        let replacementTab = try #require(controller.selectedTab(inPane: sourcePane))
        let replacementPanelID = try #require(workspace.panelIdFromSurfaceId(replacementTab.id))

        #expect(controller.selectedTab(inPane: movedPane)?.id == sourceTab.id)
        #expect(replacementTab.id != sourceTab.id)
        try expectRemoteTerminal(replacementPanelID, in: workspace, persistent: persistent)
    }

    @Test
    func localSplitButtonStillCreatesLocalTerminal() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let controller = workspace.bonsplitController
        let sourcePane = try #require(controller.focusedPaneId)
        let newPane = try #require(controller.splitPane(sourcePane, orientation: .horizontal))
        let newTab = try #require(controller.selectedTab(inPane: newPane))
        let panelID = try #require(workspace.panelIdFromSurfaceId(newTab.id))
        let panel = try #require(workspace.terminalPanel(for: panelID))

        #expect(panel.surface.debugInitialCommand() == nil)
        #expect(!panel.surface.isRemoteTerminal)
        #expect(!workspace.activeRemoteTerminalSurfaceIds.contains(panelID))
    }

    private func remoteWorkspace(persistent: Bool) -> Workspace {
        let workspace = Workspace()
        workspace.configureRemoteConnection(WorkspaceRemoteConfiguration(
            destination: "test.example",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-ui-split-test.sock",
            terminalStartupCommand: "/usr/bin/true",
            preserveAfterTerminalExit: persistent,
            persistentDaemonSlot: persistent ? "ssh-ui-split-test" : nil
        ), autoConnect: false)
        return workspace
    }

    private func expectRemoteTerminal(_ panelID: UUID, in workspace: Workspace, persistent: Bool) throws {
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let command = try #require(workspace.effectiveRemoteTerminalStartupCommand(from: workspace.remoteConfiguration))
        #expect(panel.surface.debugInitialCommand() == command)
        #expect(panel.surface.isRemoteTerminal)
        #expect(workspace.activeRemoteTerminalSurfaceIds.contains(panelID))
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(panelID))
        if persistent {
            let sessionID = try #require(workspace.remotePTYSessionIDsByPanelId[panelID])
            #expect(panel.surface.debugAdditionalEnvironmentForTesting()[Workspace.remotePTYSessionEnvironmentKey] == sessionID)
        }
    }
#endif
}
