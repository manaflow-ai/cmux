import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace remote directory provenance")
struct WorkspaceRemoteDirectoryProvenanceTests {
    @MainActor
    @Test("local terminal in remote workspace presents requested cwd before live report")
    func localTerminalInRemoteWorkspacePresentsRequestedDirectoryBeforeLiveReport() throws {
        let localDirectory = "/Users/alice/development"
        let localTerminalDirectory = "/Users/alice/local-tools"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        #expect(workspace.presentedCurrentDirectory == nil)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == remoteDirectory)

        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: localTerminalDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        workspace.panelDirectories.removeValue(forKey: localPanel.id)

        #expect(workspace.allowsLocalDirectoryFallback(panelId: localPanel.id))
        #expect(workspace.effectivePanelDirectory(panelId: localPanel.id) == localTerminalDirectory)
        #expect(workspace.presentedCurrentDirectory == localTerminalDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == nil)
        #expect(workspace.updatePanelDirectory(panelId: localPanel.id, directory: localTerminalDirectory))
        #expect(workspace.reportedPanelDirectory(panelId: localPanel.id) == localTerminalDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == nil)
        #expect(workspace.sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: [localPanel.id]) == [
            localTerminalDirectory,
        ])
    }

    @MainActor
    @Test("remote tmux mirror does not use raw currentDirectory before remote report")
    func remoteTmuxMirrorDoesNotUseRawCurrentDirectoryBeforeRemoteReport() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let workspace = Workspace(workingDirectory: localDirectory)
        let panelId = try #require(workspace.focusedPanelId)
        workspace.isRemoteTmuxMirror = true
        #expect(workspace.updatePanelDirectory(panelId: panelId, directory: localDirectory))

        #expect(workspace.usesRemoteDirectoryProvenance)
        #expect(!workspace.allowsLocalDirectoryFallback(panelId: panelId))
        #expect(workspace.reportedPanelDirectory(panelId: panelId) == nil)
        #expect(workspace.presentedCurrentDirectory == nil)
        #expect(workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: panelId) == nil)

        workspace.updateRemotePanelDirectory(panelId: panelId, directory: remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: panelId) == remoteDirectory)
        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
        #expect(workspace.remoteTmuxNewWindowWorkingDirectory(forSourcePanelId: panelId) == remoteDirectory)
    }

    @MainActor
    @Test("reconnect keeps remote trust guard for agent panels")
    func reconnectKeepsRemoteTrustGuardForAgentPanels() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        #expect(agentPanel.workingDirectory == remoteDirectory)
        #expect(workspace.remoteDirectoryReportPanelIds.contains(agentPanel.id))

        workspace.disconnectRemoteConnection()
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(agentPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == nil)

        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(agentPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == nil)
        #expect(workspace.presentedCurrentDirectory == nil)

        workspace.updateRemotePanelDirectory(panelId: agentPanel.id, directory: remoteDirectory)
        #expect(workspace.remoteDirectoryReportPanelIds.contains(agentPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == remoteDirectory)
    }

    @MainActor
    @Test("reattached agent panel restores trusted remote directory provenance")
    func reattachedAgentPanelRestoresTrustedRemoteDirectoryProvenance() throws {
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: "/Users/alice/development", initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        let detached = try #require(workspace.detachSurface(panelId: agentPanel.id))
        #expect(detached.directoryIsTrustedRemoteReport)

        let attachedPanelId = try #require(workspace.attachDetachedSurface(detached, inPane: paneId, focus: true))
        #expect(attachedPanelId == agentPanel.id)
        #expect(workspace.remoteDirectoryReportPanelIds.contains(agentPanel.id))
        #expect(workspace.remoteDirectoryTrustRequiredPanelIds.contains(agentPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == remoteDirectory)
    }

    @MainActor
    @Test("generic surface directory reports remain untrusted for remote panels")
    func genericSurfaceDirectoryReportsRemainUntrustedForRemotePanels() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)

        manager.updateSurfaceDirectory(tabId: workspace.id, surfaceId: remotePanelId, directory: localDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: remotePanelId) == nil)
        #expect(workspace.trustedRemoteCurrentDirectory == nil)

        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: remotePanelId, directory: remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: remotePanelId) == remoteDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == remoteDirectory)
        #expect(workspace.currentDirectory == localDirectory)
    }

    @MainActor
    @Test("generic reports cannot overwrite trusted agent directory")
    func genericReportsCannotOverwriteTrustedAgentDirectory() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))

        #expect(!workspace.updatePanelDirectory(panelId: agentPanel.id, directory: localDirectory))
        #expect(workspace.panelDirectories[agentPanel.id] == remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == remoteDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == remoteDirectory)
        #expect(workspace.closePanel(agentPanel.id, force: true))
        #expect(!workspace.remoteDirectoryReportPanelIds.contains(agentPanel.id))
        #expect(!workspace.remoteDirectoryTrustRequiredPanelIds.contains(agentPanel.id))
    }

    @MainActor
    @Test("legacy remote snapshots require trusted cwd after restore")
    func legacyRemoteSnapshotsRequireTrustedDirectoryAfterRestore() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        workspace.updatePanelGitBranch(panelId: remotePanelId, branch: "remote-main", isDirty: false)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == remotePanelId })
        snapshot.panels[panelIndex].directoryIsTrustedRemoteReport = nil
        snapshot.panels[panelIndex].directoryRequiresRemoteTrust = nil
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.isRemoteTerminal = nil
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[remotePanelId])
        #expect(restored.panelDirectories[restoredPanelId] == remoteDirectory)
        #expect(restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))
        #expect(!restored.remoteDirectoryReportPanelIds.contains(restoredPanelId))
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == nil)
        #expect(restored.presentedCurrentDirectory == nil)
        #expect(restored.sidebarGitBranchesInDisplayOrder(orderedPanelIds: [restoredPanelId]).isEmpty)
    }

    @MainActor
    @Test("trust-required remote restore does not launch with remote cwd as local")
    func trustRequiredRemoteRestoreDoesNotLaunchWithRemoteDirectoryAsLocal() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        workspace.disconnectRemoteConnection()
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[remotePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        #expect(restored.panelDirectories[restoredPanelId] == remoteDirectory)
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == nil)
    }

    @MainActor
    @Test("known-local terminal in remote workspace restores local cwd")
    func knownLocalTerminalInRemoteWorkspaceRestoresLocalDirectory() throws {
        let workspaceDirectory = "/Users/alice/development"
        let localTerminalDirectory = "/Users/alice/local-tools"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: workspaceDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: localTerminalDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == localPanel.id })
        snapshot.panels[panelIndex].directoryIsTrustedRemoteReport = nil
        snapshot.panels[panelIndex].directoryRequiresRemoteTrust = nil
        var terminalSnapshot = try #require(snapshot.panels[panelIndex].terminal)
        terminalSnapshot.isRemoteTerminal = false
        snapshot.panels[panelIndex].terminal = terminalSnapshot

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[localPanel.id])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        #expect(restoredPanel.requestedWorkingDirectory == localTerminalDirectory)
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == localTerminalDirectory)
        #expect(!restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))
    }

    @MainActor
    @Test("trust-required agent restore does not capture remote cwd as local")
    func trustRequiredAgentRestoreDoesNotCaptureRemoteDirectoryAsLocal() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        workspace.disconnectRemoteConnection()
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[agentPanel.id])
        let restoredAgentPanel = try #require(restored.panels[restoredPanelId] as? AgentSessionPanel)
        #expect(restoredAgentPanel.workingDirectory == nil)
        #expect(restored.panelDirectories[restoredPanelId] == remoteDirectory)
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == nil)
    }

    @MainActor
    @Test("local fallback panels in remote workspaces keep sidebar git metadata")
    func localFallbackPanelsInRemoteWorkspacesKeepSidebarGitMetadata() throws {
        let localDirectory = "/Users/alice/development"
        let localPanelDirectory = "/Users/alice/local-tools"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: localPanelDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        workspace.panelDirectories.removeValue(forKey: localPanel.id)
        workspace.updatePanelGitBranch(panelId: localPanel.id, branch: "local-main", isDirty: false)
        workspace.updatePanelPullRequest(
            panelId: localPanel.id,
            number: 7,
            label: "#7",
            url: try #require(URL(string: "https://example.com/pr/7")),
            status: .open
        )

        #expect(workspace.reportedPanelDirectory(panelId: localPanel.id) == nil)
        #expect(workspace.effectivePanelDirectory(panelId: localPanel.id) == localPanelDirectory)
        #expect(workspace.reportedPanelGitBranch(panelId: localPanel.id)?.branch == "local-main")
        #expect(workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: [localPanel.id]).map(\.branch) == ["local-main"])
        #expect(workspace.sidebarPullRequestsInDisplayOrder(orderedPanelIds: [localPanel.id]).map(\.label) == ["#7"])
    }

    @MainActor
    @Test("local fallback directory does not define remote home")
    func localFallbackDirectoryDoesNotDefineRemoteHome() throws {
        let localDirectory = "/Users/alice/development"
        let localProjectDirectory = "/Users/alice/project"
        let remoteProjectDirectory = "~/project"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteProjectDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: localProjectDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        workspace.panelDirectories.removeValue(forKey: localPanel.id)

        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [
            remotePanelId,
            localPanel.id,
        ]) == [
            remoteProjectDirectory,
            localProjectDirectory,
        ])
    }

    @MainActor
    @Test("git probe ignores remote workspace current directory fallback")
    func gitProbeIgnoresRemoteWorkspaceCurrentDirectoryFallback() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let localPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: nil,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        workspace.currentDirectory = remoteDirectory

        #expect(workspace.terminalPanel(for: localPanel.id)?.requestedWorkingDirectory == nil)
        #expect(workspace.allowsLocalDirectoryFallback(panelId: localPanel.id))
        #expect(manager.gitProbeDirectory(for: workspace, panelId: localPanel.id) == nil)
        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [localPanel.id]) == [])
    }

    @MainActor
    @Test("reported cwd re-trusts guarded remote agent panels")
    func reportedDirectoryRetrustsGuardedRemoteAgentPanels() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: remotePanelId, directory: remoteDirectory)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        workspace.disconnectRemoteConnection()
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)

        manager.updateReportedSurfaceDirectory(tabId: workspace.id, surfaceId: agentPanel.id, directory: remoteDirectory)
        #expect(workspace.remoteDirectoryReportPanelIds.contains(agentPanel.id))
        #expect(workspace.reportedPanelDirectory(panelId: agentPanel.id) == remoteDirectory)
    }

    @MainActor
    @Test("legacy local agent in remote workspace restores local cwd")
    func legacyLocalAgentInRemoteWorkspaceRestoresLocalDirectory() throws {
        let localDirectory = "/Users/alice/development"
        let agentDirectory = "/Users/alice/local-agent"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(workingDirectory: localDirectory, initialTerminalCommand: sshCommand)
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: paneId,
            rendererKind: .react,
            workingDirectory: agentDirectory,
            focus: true
        ))
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == agentPanel.id })
        snapshot.panels[panelIndex].directoryIsTrustedRemoteReport = nil
        snapshot.panels[panelIndex].directoryRequiresRemoteTrust = nil

        let restored = Workspace()
        let restoredPanelId = try #require(restored.restoreSessionSnapshot(snapshot)[agentPanel.id])
        let restoredAgentPanel = try #require(restored.panels[restoredPanelId] as? AgentSessionPanel)
        #expect(restoredAgentPanel.workingDirectory == agentDirectory)
        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == agentDirectory)
        #expect(!restored.remoteDirectoryTrustRequiredPanelIds.contains(restoredPanelId))
    }

    private func sshRemoteConfiguration(command: String) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "seepine@192.168.5.20",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: "relay-\(UUID().uuidString)",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-issue-7268-\(UUID().uuidString).sock",
            terminalStartupCommand: command
        )
    }
}
