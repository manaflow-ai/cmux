import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Extension worktree removal candidates")
@MainActor
struct ExtensionWorktreeRemovalCandidateTests {
    @Test("remote workspace paths are not treated as local removal candidates")
    func remoteWorkspacePathsAreExcluded() {
        let worktree = "/Users/me/repo/.cmux/worktrees/wt-a"
        let panelId = UUID()
        let workspace = Workspace(workingDirectory: worktree)
        workspace.panelDirectories[panelId] = worktree + "/remote-pane"
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "remote.example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )

        #expect(workspace.extensionWorktreeRemovalCandidateDirectories().isEmpty)
    }

    @Test("remote tmux mirror paths are not treated as local removal candidates")
    func remoteTmuxMirrorPathsAreExcluded() {
        let worktree = "/Users/me/repo/.cmux/worktrees/wt-a"
        let panelId = UUID()
        let workspace = Workspace(workingDirectory: worktree)
        workspace.panelDirectories[panelId] = worktree + "/remote-pane"
        workspace.isRemoteTmuxMirror = true

        #expect(workspace.extensionWorktreeRemovalCandidateDirectories().isEmpty)
    }
}
