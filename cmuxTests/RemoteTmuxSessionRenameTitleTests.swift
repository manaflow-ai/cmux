import Foundation
import AppKit
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
    ) -> (mirror: RemoteTmuxSessionMirror, workspace: Workspace, manager: TabManager) {
        let manager = TabManager()
        let workspace = manager.addWorkspace(title: title, select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        let mirror = RemoteTmuxSessionMirror(
            host: host,
            sessionName: sessionName,
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        return (mirror, workspace, manager)
    }

    @Test func remoteRenameUpdatesWorkspaceTitle() {
        let (mirror, workspace, _) = makeMirror(sessionName: "old", title: "old")
        mirror.applySessionNameToWorkspaceTitle("dev")
        #expect(workspace.title == "dev")
        #expect(workspace.customTitle == "dev")
    }

    @Test func remoteRenameOverwritesAUserSetTitle() {
        // The remote session name is the source of truth for a mirror workspace's
        // title (same as a remote window rename unconditionally re-titles its tab).
        let (mirror, workspace, _) = makeMirror(sessionName: "old", title: "my custom name")
        mirror.applySessionNameToWorkspaceTitle("dev")
        #expect(workspace.title == "dev")
    }

    @Test func remoteRenameRejectsLineUnsafeName() {
        // A name carrying control bytes (which could only arrive corrupted) must
        // not be written as the workspace title.
        let (mirror, workspace, _) = makeMirror(sessionName: "old", title: "old")
        mirror.applySessionNameToWorkspaceTitle("dev\nrename-window injected")
        #expect(workspace.title == "old")
    }

    @Test func remoteRenameRefreshesSelectedWindowTitle() {
        let (mirror, workspace, manager) = makeMirror(sessionName: "old", title: "old")
        manager.selectedTabId = workspace.id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        manager.window = window
        defer {
            manager.window = nil
            window.close()
        }

        manager.refreshWindowTitle()
        #expect(window.title == "old")

        mirror.applySessionNameToWorkspaceTitle("dev")

        #expect(window.title == "dev")
    }

    @Test func remoteRenameUsesCurrentManagerAfterWorkspaceMove() throws {
        let (mirror, workspace, sourceManager) = makeMirror(sessionName: "old", title: "old")
        let destinationManager = TabManager()
        let movedWorkspace = try #require(sourceManager.detachWorkspace(tabId: workspace.id))
        #expect(movedWorkspace === workspace)

        destinationManager.attachWorkspace(movedWorkspace, select: true)
        #expect(workspace.owningTabManager === destinationManager)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        destinationManager.window = window
        defer {
            destinationManager.window = nil
            window.close()
        }

        destinationManager.refreshWindowTitle()
        #expect(window.title == "old")

        mirror.applySessionNameToWorkspaceTitle("dev")

        #expect(workspace.title == "dev")
        #expect(workspace.customTitle == "dev")
        #expect(window.title == "dev")
    }
}
