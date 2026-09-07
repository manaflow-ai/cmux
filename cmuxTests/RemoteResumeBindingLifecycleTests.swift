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
        let authority = try #require(WorkspaceRemoteTerminalAuthority(configuration: configuration))
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

    @Test
    func persistentBindingOnlyRestoreTracksStartupCommandUntilPromptReturns() throws {
        let fixture = try makeRelayedFixture()
        let suiteName = "cmux-remote-resume-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let socketPath = reserveRemoteRestoreSocket()
        defer { cleanupRemoteRestoreSocket(socketPath) }

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { restoredWorkspace.teardownAllPanels() }
        let restoredIDs = restoredWorkspace.restoreSessionSnapshot(fixture.snapshot)
        let restoredSurfaceID = try #require(restoredIDs[fixture.surfaceID])
        #expect(restoredWorkspace.restoredAgentResumeStatesByPanelId[restoredSurfaceID] == .awaitingAutoResumeCommand)

        restoredWorkspace.updatePanelShellActivityState(panelId: restoredSurfaceID, state: .commandRunning)
        #expect(restoredWorkspace.restoredAgentResumeStatesByPanelId[restoredSurfaceID] == .autoResumeCommandRunning)
        let runningBinding = try #require(restoredWorkspace.sessionSnapshot(includeScrollback: false)
            .panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding)
        #expect(runningBinding.autoResume == true)

        restoredWorkspace.updatePanelShellActivityState(panelId: restoredSurfaceID, state: .promptIdle)
        #expect(restoredWorkspace.restoredAgentResumeStatesByPanelId[restoredSurfaceID] == nil)
        let retiredBinding = try #require(restoredWorkspace.sessionSnapshot(includeScrollback: false)
            .panels.first { $0.id == restoredSurfaceID }?.terminal?.resumeBinding)
        #expect(retiredBinding.autoResume == false)
    }
}
