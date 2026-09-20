import AppKit
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockSocketLifecycleTests {
    @MainActor
    func detachedTerminalTransfer(
        panel: any Panel,
        sourceWorkspaceId: UUID,
        sessionRestoreSourceWorkspaceId: UUID? = nil,
        directory: String? = nil,
        cachedTitle: String? = nil,
        customTitle: String? = nil,
        customTitleSource: Workspace.CustomTitleSource? = nil,
        directoryIsTrustedRemoteReport: Bool = false,
        restorableAgent: SessionRestorableAgentSnapshot? = nil,
        restorableAgentResumeState: Workspace.RestoredAgentResumeState? = nil,
        restoredAgentCompletedGeneration: RestoredAgentCompletedGeneration? = nil,
        shellActivityState: PanelShellActivityState? = nil,
        restoredResumeSessionWorkingDirectory: String? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        managedAgentResumeBinding: SurfaceResumeBindingSnapshot? = nil,
        agentRuntime: Workspace.DetachedAgentRuntimeState? = nil,
        isRemoteTerminal: Bool = false,
        remoteTerminalSessionPhase: WorkspaceRemoteTerminalSessionPhase? = nil,
        remotePTYSessionID: String? = nil
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sessionRestoreSourceWorkspaceId: sessionRestoreSourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: directory,
            directoryIsTrustedRemoteReport: directoryIsTrustedRemoteReport,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: cachedTitle,
            customTitle: customTitle,
            customTitleSource: customTitleSource,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: restorableAgent,
            restorableAgentResumeState: restorableAgentResumeState,
            restoredAgentCompletedGeneration: restoredAgentCompletedGeneration,
            shellActivityState: shellActivityState,
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            resumeBinding: resumeBinding,
            managedAgentResumeBinding: managedAgentResumeBinding,
            agentRuntime: agentRuntime,
            isRemoteTerminal: isRemoteTerminal,
            remoteTerminalSessionPhase: remoteTerminalSessionPhase,
            remoteRelayPort: nil,
            remotePTYSessionID: remotePTYSessionID,
            remoteCleanupConfiguration: nil
        )
    }

    @Test("Persistent SSH agent-hook ownership survives a Dock snapshot")
    @MainActor
    func persistentSSHAgentHookOwnershipSurvivesDockSnapshot() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        let remotePTYSessionID = "cmux-remote-pty-\(UUID().uuidString)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume remote-session",
            cwd: "/srv/project",
            checkpointId: "remote-session",
            source: "agent-hook",
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: sourceWorkspaceId,
                surfaceID: panel.id,
                persistentPTYSessionID: remotePTYSessionID
            ))
        )
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            resumeBinding: binding,
            managedAgentResumeBinding: binding,
            isRemoteTerminal: true,
            remoteTerminalSessionPhase: .connected,
            remotePTYSessionID: remotePTYSessionID
        )

        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        let snapshot = store.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: .empty,
            surfaceResumeBindingIndex: .empty
        )
        let terminal = try #require(snapshot.panels.first { $0.id == panel.id }?.terminal)
        #expect(terminal.wasAgentRunning == true)
    }
}
