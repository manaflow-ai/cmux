import AppKit
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Setup shared by the New Workspace routing suites.
@MainActor
enum RemoteTmuxRoutingFixture {
    private static let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"

    /// Sets the ssh stub for the caller's whole scope; the returned closure
    /// restores the previous value and belongs in the FIRST `defer`, so it
    /// runs after every later-registered teardown (detach included).
    static func pinStubSSH(_ stub: String) -> () -> Void {
        let prior = ProcessInfo.processInfo.environment[sshOverrideKey]
        setenv(sshOverrideKey, stub, 1)
        return {
            if let prior {
                setenv(sshOverrideKey, prior, 1)
            } else {
                unsetenv(sshOverrideKey)
            }
        }
    }

    /// Mirrors `sessionName` on `host` into `manager` and selects the mirror workspace.
    static func mirrorSelectedSession(
        controller: RemoteTmuxController,
        host: RemoteTmuxHost,
        sessionName: String,
        into manager: TabManager
    ) throws -> Workspace {
        _ = controller.transport(for: host)
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: sessionName))
        #expect(try controller.mirrorSession(host: host, sessionName: sessionName, into: manager))
        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.selectWorkspace(workspace)
        return workspace
    }

    /// Registers `manager` as a main-window context with a resolvable window
    /// (the shape `performNewWorkspaceAction`'s preferred-context path needs).
    static func registerWindowedContext(
        appDelegate: AppDelegate,
        manager: TabManager
    ) -> (windowId: UUID, window: NSWindow) {
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
        // A registered context resolves its window from the context itself, and naming
        // the NSWindow by identifier is not enough any more, so attach it.
        appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }?.window = window
        return (windowId, window)
    }
}
