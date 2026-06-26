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
struct RightSidebarRemoteFileRootTests {
    @Test
    func filesRevertToLocalRootAfterNonPersistentSSHSessionEnds() throws {
        let localPath = NSTemporaryDirectory() + "cmux-local-files-\(UUID().uuidString)"
        let workspace = Workspace()
        workspace.currentDirectory = localPath
        let remotePanelID = try #require(workspace.focusedTerminalPanel?.id)
        let panel = RightSidebarToolPanel(workspace: workspace, mode: .files)
        let store = panel.fileExplorerStore

        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev@ubuntu-host",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: "ssh dev@ubuntu-host"
            ),
            autoConnect: false
        )
        workspace.currentDirectory = "/home/dev/project"
        panel.syncWorkspaceRoot(from: workspace)
        #expect(store.provider is SSHFileExplorerProvider)
        #expect(store.displayRootPath.hasPrefix("ssh://dev@ubuntu-host"))

        workspace.markRemoteTerminalSessionEnded(surfaceId: remotePanelID, relayPort: nil)
        workspace.currentDirectory = localPath
        panel.syncWorkspaceRoot(from: workspace)

        #expect(store.provider is LocalFileExplorerProvider)
        #expect(store.rootPath == localPath)
        #expect(!store.displayRootPath.hasPrefix("ssh://"))
    }
}
