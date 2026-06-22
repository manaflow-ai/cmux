import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for syncing a remote tmux `rename-session` back onto the
/// mirror's cmux workspace title (the reverse of the cmux→tmux rename push).
/// A remote `tmux rename-session` arrives as `%session-renamed`; the mirror must
/// re-title its sidebar workspace, and must do so WITHOUT re-propagating to
/// `rename-session` (which would feed back on itself).
@MainActor
@Suite(.serialized)
struct RemoteTmuxSessionRenameTitleTests {
    private func makeMirror(
        sessionName: String,
        title: String?
    ) -> (mirror: RemoteTmuxSessionMirror, workspace: Workspace) {
        let manager = TabManager()
        let workspace = manager.addWorkspace(title: title, select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        let mirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: sessionName,
            connection: connection,
            workspace: workspace
        )
        return (mirror, workspace)
    }

    @Test func remoteRenameUpdatesWorkspaceTitle() {
        let (mirror, workspace) = makeMirror(sessionName: "old", title: "old")
        mirror.applySessionNameToWorkspaceTitle("dev")
        #expect(workspace.title == "dev")
        #expect(workspace.customTitle == "dev")
    }

    @Test func remoteRenameOverwritesAUserSetTitle() {
        // The remote session name is the source of truth for a mirror workspace's
        // title (same as a remote window rename unconditionally re-titles its tab).
        let (mirror, workspace) = makeMirror(sessionName: "old", title: "my custom name")
        mirror.applySessionNameToWorkspaceTitle("dev")
        #expect(workspace.title == "dev")
    }

    @Test func remoteRenameRejectsLineUnsafeName() {
        // A name carrying control bytes (which could only arrive corrupted) must
        // not be written as the workspace title.
        let (mirror, workspace) = makeMirror(sessionName: "old", title: "old")
        mirror.applySessionNameToWorkspaceTitle("dev\nrename-window injected")
        #expect(workspace.title == "old")
    }
}
