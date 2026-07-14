import CmuxGit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pull request panel remote workspace")
struct PullRequestPanelRemoteWorkspaceTests {
    @MainActor
    @Test("pull request panel never projects a remote path into the local Git service")
    func pullRequestPanelDoesNotProjectRemoteDirectory() throws {
        let workspace = Workspace(workingDirectory: "/Users/alice/development")
        let panelId = try #require(workspace.focusedPanelId)
        workspace.isRemoteTmuxMirror = true
        workspace.updateRemotePanelDirectory(panelId: panelId, directory: "/home/alice/project")

        #expect(workspace.presentedCurrentDirectory == "/home/alice/project")
        #expect(PullRequestPanelWorkspaceView.pullRequestInput(for: workspace) == PullRequestWorkspaceInput(
            directory: "",
            branchHint: nil
        ))
    }
}
