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

        manager.updateRemoteSurfaceDirectory(tabId: workspace.id, surfaceId: remotePanelId, directory: remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: remotePanelId) == remoteDirectory)
        #expect(workspace.trustedRemoteCurrentDirectory == remoteDirectory)
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
