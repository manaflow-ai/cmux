import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror close contract
/// (https://github.com/manaflow-ai/cmux/pull/7264 review): closing a mirrored
/// remote-tmux workspace must DETACH from the remote session, never `kill-session`
/// it. The ssh-tmux author flagged that with mirrors living as plain workspaces in
/// the current window, the natural "close this tab to get it off my screen" gesture
/// would silently kill the user's live tmux session on the server. Killing a remote
/// session is only ever an explicit disconnect action, never a side effect of
/// closing a tab, a window, or quitting the app.
///
/// The seam that used to translate a tab close into "kill on commit" is
/// `TabManager.markRemoteTmuxKillOnWindowCloseIfNeeded`, which set the window
/// kill-on-close marker in `RemoteTmuxWindowRegistry`. After the fix that seam must
/// never mark a mirror for kill, so every close path (non-last tab, last-tab window
/// close, and the app-quit deferral gate) detaches and the remote session survives.
/// The marker is set-then-consumed synchronously inside the real close gesture, so
/// this test exercises the marking decision directly to observe it deterministically.
@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorCloseDetachTests {
    /// The mark seam must NOT flag a mirror workspace's window for kill-on-close:
    /// the close detaches, the remote tmux session survives for resume. Before the
    /// fix this marked the window for kill; after, it never does.
    @Test func markSeamDoesNotMarkMirrorForKill() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.workspace.isRemoteTmuxMirror = true
        harness.manager.markRemoteTmuxKillOnWindowCloseIfNeeded(for: [harness.workspace])

        #expect(
            !harness.appDelegate.remoteTmuxController
                .windowsMarkedForKillOnClose()
                .contains(harness.windowId)
        )
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let manager: TabManager
        let workspace: Workspace

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            windowId = appDelegate.createMainWindow()
            manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            workspace = try #require(manager.selectedWorkspace)
        }

        func tearDown() {
            workspace.isRemoteTmuxMirror = false
            // Clear any marker so it can't leak into another serialized test.
            appDelegate.remoteTmuxController.consumeKillSessionsOnWindowClose(windowId: windowId)
            let identifier = "cmux.main.\(windowId.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
