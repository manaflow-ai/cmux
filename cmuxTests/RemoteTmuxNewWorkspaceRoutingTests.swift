import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Truth-table coverage for `RemoteTmuxController.newWorkspaceRoutesRemote`, the
/// pure remote-vs-local decision behind both `handleRemoteWindowNewWorkspaceRequested`
/// (does plain New Workspace / ⌘N spawn a tmux session on the window's host?) and the
/// "New Local Workspace" File-menu item's visibility (shown exactly when that answer
/// is `true`). Sharing one decision keeps the menu's shown-state and the action in
/// lockstep. The factored-out form takes booleans so the edges are testable without a
/// live registry, window, or tab manager.
@Suite struct RemoteTmuxNewWorkspaceRoutingTests {
    /// No host bound to the window → plain New Workspace stays local, so the item hides.
    /// The manager/mirror flags are irrelevant once there is no host.
    @Test func noHostRoutesLocal() {
        #expect(RemoteTmuxController.newWorkspaceRoutesRemote(
            hasHost: false, hasManager: false, activeTabIsMirror: false) == false)
        #expect(RemoteTmuxController.newWorkspaceRoutesRemote(
            hasHost: false, hasManager: true, activeTabIsMirror: true) == false)
    }

    /// A host is bound but the tab manager isn't resolvable (the window is mid-teardown):
    /// route remote to match the handler, which returns `true` and no-ops the creation.
    @Test func hostWithoutManagerRoutesRemote() {
        #expect(RemoteTmuxController.newWorkspaceRoutesRemote(
            hasHost: true, hasManager: false, activeTabIsMirror: false) == true)
    }

    /// Host + manager + the active workspace is a mirror → New Workspace spawns a remote
    /// session, so "New Local Workspace" is shown as the local escape hatch.
    @Test func hostWithActiveMirrorRoutesRemote() {
        #expect(RemoteTmuxController.newWorkspaceRoutesRemote(
            hasHost: true, hasManager: true, activeTabIsMirror: true) == true)
    }

    /// Host + manager but the active workspace is a dragged-in LOCAL tab → New Workspace
    /// stays local (no unwanted tmux session), and the item stays hidden because plain
    /// New Workspace already does the right thing.
    @Test func hostWithActiveLocalTabRoutesLocal() {
        #expect(RemoteTmuxController.newWorkspaceRoutesRemote(
            hasHost: true, hasManager: true, activeTabIsMirror: false) == false)
    }
}
