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
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        workspace.configureRemoteConnection(sshRemoteConfiguration(command: sshCommand), autoConnect: false)
        #expect(workspace.presentedCurrentDirectory == nil)

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

        workspace.updateRemotePanelDirectory(panelId: panelId, directory: remoteDirectory)
        #expect(workspace.reportedPanelDirectory(panelId: panelId) == remoteDirectory)
        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
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
