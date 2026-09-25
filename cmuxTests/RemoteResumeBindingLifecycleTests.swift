import AppKit
import CmuxControlSocket
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteResumeBindingTests {
    @Test
    func endedRemoteWorkspaceSessionCannotProvideResumeContext() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let configuration = remoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        workspace.trackRemoteTerminalSurface(panelID)
        let authority = try #require(
            workspace.remoteConfiguration.flatMap {
                WorkspaceRemoteTerminalAuthority(configuration: $0)
            }
        )
        #expect(workspace.markRemoteTerminalSessionConnected(surfaceId: panelID, authority: authority))

        let sessionID = Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)
        workspace.remotePTYSessionIDsByPanelId[panelID] = sessionID
        let liveContext = try #require(workspace.persistentSSHResumeContext(panelID: panelID))
        #expect(liveContext.persistentPTYSessionID == sessionID)

        workspace.remoteTerminalSessionStatesBySurfaceId[panelID] = WorkspaceRemoteTerminalSessionState(
            phase: .ended,
            authority: authority,
            terminalLifecycleID: nil
        )
        #expect(workspace.activeRemoteTerminalSurfaceIds.contains(panelID))
        #expect(workspace.persistentSSHResumeContext(panelID: panelID) == nil)

        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume ended-remote-session",
            cwd: "/srv/project",
            checkpointId: "ended-remote-session",
            source: "agent-hook",
            autoResume: true,
            launchFlavor: .persistentSSH(liveContext)
        )
        #expect(!binding.recordsRunningPersistentSSHAgent(in: workspace.persistentSSHResumeContext(panelID: panelID)))
    }
}
