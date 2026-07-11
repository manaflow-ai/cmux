import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// New Workspace routing for remote-tmux mirrors: when the active workspace is
/// a mirrored tmux session, `performNewWorkspaceAction` must route the request
/// to the session's host instead of creating a local workspace.
@MainActor
@Suite(.serialized)
struct RemoteTmuxNewWorkspaceHostRoutingTests {
    private let hostA = RemoteTmuxHost(destination: "user@alpha")

    /// Caches a transport for `host` whose ssh binary is a no-op stub, so any
    /// async new-session attempt can never spawn a real ssh.
    private func cacheStubTransport(controller: RemoteTmuxController, host: RemoteTmuxHost) {
        setenv("CMUX_REMOTE_TMUX_SSH_FOR_TESTING", "/usr/bin/false", 1)
        defer { unsetenv("CMUX_REMOTE_TMUX_SSH_FOR_TESTING") }
        _ = controller.transport(for: host)
    }

    private func mirrorSelectedSession(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String,
        into manager: TabManager
    ) throws -> Workspace {
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: sessionName))
        #expect(try controller.mirrorSession(host: host, sessionName: sessionName, into: manager))
        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.selectWorkspace(workspace)
        return workspace
    }

    @Test func newWorkspaceOnActiveMirrorSuppressesLocalCreation() throws {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let controller = appDelegate.remoteTmuxController
        let manager = TabManager()
        let localWorkspace = try #require(manager.selectedWorkspace)
        cacheStubTransport(controller: controller, host: hostA)
        let mirrorWorkspace = try mirrorSelectedSession(
            controller: controller, host: hostA, sessionName: "dev", into: manager
        )

        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        manager.window = window
        defer {
            window.close()
            manager.window = nil
            if controller.sessionMirror(host: hostA, sessionName: "dev") != nil {
                controller.detach(host: hostA, sessionName: "dev")
            }
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        // Active workspace is the mirror: the action is claimed for the remote
        // host and no local workspace appears.
        #expect(manager.selectedTab?.id == mirrorWorkspace.id)
        let tabsBefore = manager.tabs.map(\.id)
        #expect(appDelegate.performNewWorkspaceAction(tabManager: manager, debugSource: "test.remoteMirror"))
        #expect(manager.tabs.map(\.id) == tabsBefore)

        // Active workspace is local: the same action creates a local workspace.
        manager.selectWorkspace(localWorkspace)
        #expect(appDelegate.performNewWorkspaceAction(tabManager: manager, debugSource: "test.localTab"))
        #expect(manager.tabs.count == tabsBefore.count + 1)
    }
}
