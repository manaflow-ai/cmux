import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The "New Local Workspace" escape hatch: `wouldNewWorkspaceSpawnRemote(in:)`
/// (the File-menu item's visibility, shown exactly when plain New Workspace
/// would go remote), `performNewLocalWorkspaceAction` (forced-local creation
/// that must produce a plain local workspace even on an active mirror), and
/// the ⌃⌘N default's alignment across both shortcut catalogs.
///
/// SSH never leaves the process: env-pinned stub for the whole test body
/// (including deferred `detach`, whose last-mirror teardown spawns
/// `ssh -O exit`), and `AppContextSerialGate` around bodies that suspend so
/// another suite's env/AppDelegate use cannot interleave.
@MainActor
@Suite(.serialized)
struct RemoteTmuxNewWorkspaceRoutingTests {
    private static let sshOverrideKey = "CMUX_REMOTE_TMUX_SSH_FOR_TESTING"
    private let host = RemoteTmuxHost(destination: "user@local-escape-hatch")

    /// Sets the ssh stub for the caller's whole scope; the returned closure
    /// restores the previous value and belongs in the FIRST `defer`, so it
    /// runs after every later-registered teardown (detach included).
    private func pinStubSSH(_ stub: String) -> () -> Void {
        let prior = ProcessInfo.processInfo.environment[Self.sshOverrideKey]
        setenv(Self.sshOverrideKey, stub, 1)
        return {
            if let prior {
                setenv(Self.sshOverrideKey, prior, 1)
            } else {
                unsetenv(Self.sshOverrideKey)
            }
        }
    }

    private func mirrorSelectedSession(
        controller: RemoteTmuxController,
        into manager: TabManager
    ) throws -> Workspace {
        _ = controller.transport(for: host)
        controller.cacheConnection(RemoteTmuxControlConnection(host: host, sessionName: "esc"))
        #expect(try controller.mirrorSession(host: host, sessionName: "esc", into: manager))
        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.selectWorkspace(workspace)
        return workspace
    }

    /// The visibility predicate flips with the ACTIVE workspace, not the window:
    /// a mirror tab shows the item, a local tab in the same manager hides it.
    @Test func menuVisibilityFollowsTheActiveWorkspace() throws {
        let restoreSSH = pinStubSSH("/usr/bin/false")
        defer { restoreSSH() }
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let localWorkspace = try #require(manager.selectedWorkspace)
        #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))

        let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
        defer { controller.detach(host: host, sessionName: "esc") }
        #expect(manager.selectedTab?.id == mirrorWorkspace.id)
        #expect(controller.wouldNewWorkspaceSpawnRemote(in: manager))

        manager.selectWorkspace(localWorkspace)
        #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))
    }

    /// New Local Workspace on an ACTIVE MIRROR creates a plain local workspace —
    /// it must not route to the remote (that is plain New Workspace's job).
    /// (The `forceLocal` skip of a CONFIGURED new-workspace override is enforced
    /// by the `!forceLocal` guards in `performNewWorkspaceCreationAction`; no
    /// override is installed here.)
    @Test func newLocalWorkspaceOnActiveMirrorCreatesLocalWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreSSH = pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let manager = TabManager()
            let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
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
                if controller.sessionMirror(host: host, sessionName: "esc") != nil {
                    controller.detach(host: host, sessionName: "esc")
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            let tabsBefore = Set(manager.tabs.map(\.id))
            #expect(appDelegate.performNewLocalWorkspaceAction(
                tabManager: manager, debugSource: "test.newLocalWorkspace"
            ))
            // Creation happened synchronously and locally: a routed request
            // would have added NO tab here (the mirror lands only after the ssh
            // round trip), so exactly one immediate non-mirror tab proves
            // forced-local.
            let createdIds = Set(manager.tabs.map(\.id)).subtracting(tabsBefore)
            #expect(createdIds.count == 1)
            let created = try #require(manager.tabs.first { createdIds.contains($0.id) })
            #expect(!created.isRemoteTmuxMirror)
        }
    }

    /// The ⌃⌘N default must agree between the app catalog (dispatch) and the
    /// CmuxSettings catalog (settings UI, conflict detection, config bindings).
    @Test func defaultShortcutAlignsAcrossCatalogs() {
        let appDefault = KeyboardShortcutSettings.Action.newLocalWorkspace.defaultShortcut
        #expect(appDefault.key == "n")
        #expect(appDefault.command)
        #expect(appDefault.control)
        #expect(!appDefault.option)
        #expect(!appDefault.shift)

        let settingsDefault = ShortcutAction.newLocalWorkspace.defaultStroke
        #expect(settingsDefault?.key == "n")
        #expect(settingsDefault?.command == true)
        #expect(settingsDefault?.control == true)
        #expect(settingsDefault?.option != true)
        #expect(settingsDefault?.shift != true)
    }
}
