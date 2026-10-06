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
/// the ⌃⌥⌘N default's alignment across both shortcut catalogs.
///
/// SSH never leaves the process: env-pinned stub for the whole test body
/// (including deferred `detach`, whose last-mirror teardown spawns
/// `ssh -O exit`), and `AppContextSerialGate` around bodies that suspend so
/// another suite's env/AppDelegate use cannot interleave.
@MainActor
@Suite(.serialized)
struct RemoteTmuxNewWorkspaceRoutingTests {
    private let host = RemoteTmuxHost(destination: "user@local-escape-hatch")

    private func mirrorSelectedSession(
        controller: RemoteTmuxController,
        into manager: TabManager
    ) throws -> Workspace {
        try RemoteTmuxRoutingFixture.mirrorSelectedSession(
            controller: controller, host: host, sessionName: "esc", into: manager
        )
    }

    /// The visibility predicate flips with the ACTIVE workspace, not the window:
    /// a mirror tab shows the item, a local tab in the same manager hides it.
    @Test func menuVisibilityFollowsTheActiveWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
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
    }

    /// A mirror detached while its workspace stays open and selected flips the
    /// predicate with no selection change. The menu cannot see that through
    /// selection, so the controller's mirror-set revision has to move too.
    @Test func detachingTheSelectedMirrorChangesTheMirrorSetRevision() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let before = controller.mirrorSet.value

            let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
            defer { controller.detach(host: host, sessionName: "esc") }
            let mirrored = controller.mirrorSet.value
            #expect(mirrored != before)
            #expect(controller.wouldNewWorkspaceSpawnRemote(in: manager))

            controller.detachMirrorWorkspaceKeptOpenLocally(workspaceId: mirrorWorkspace.id)
            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))
            #expect(controller.mirrorSet.value != mirrored)
        }
    }

    /// The alert shows tmux's or ssh's own last line, never a whole stderr.
    @Test func newSessionFailureReasonIsOneBoundedLine() {
        #expect(RemoteTmuxController.newSessionFailureReason("") == nil)
        #expect(RemoteTmuxController.newSessionFailureReason(" \n\t\n") == nil)
        #expect(RemoteTmuxController.newSessionFailureReason("duplicate session: work\n") == "duplicate session: work")
        let banner = "Welcome to host\nAuthorized use only\n\nPermission denied (publickey).\n\n"
        #expect(RemoteTmuxController.newSessionFailureReason(banner) == "Permission denied (publickey).")
        #expect(RemoteTmuxController.newSessionFailureReason("bad\u{1B}[31m name\u{07}") == "bad[31m name")
        let long = String(repeating: "x", count: 500)
        #expect(RemoteTmuxController.newSessionFailureReason(long) == String(repeating: "x", count: 200) + "…")
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
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let manager = TabManager()
            let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
            let (windowId, window) = RemoteTmuxRoutingFixture.registerWindowedContext(
                appDelegate: appDelegate, manager: manager
            )
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

    /// The ⌃⌥⌘N default must agree between the app catalog (dispatch) and the
    /// settings catalog (what the Keyboard Shortcuts pane shows and edits).
    @Test func defaultShortcutAlignsAcrossCatalogs() {
        let appDefault = KeyboardShortcutSettings.Action.newLocalWorkspace.defaultShortcut
        #expect(appDefault.key == "n")
        #expect(appDefault.command)
        #expect(appDefault.control)
        #expect(appDefault.option)
        #expect(!appDefault.shift)

        let settingsDefault = ShortcutAction.newLocalWorkspace.defaultStroke
        #expect(settingsDefault?.key == "n")
        #expect(settingsDefault?.command == true)
        #expect(settingsDefault?.control == true)
        #expect(settingsDefault?.option == true)
        #expect(settingsDefault?.shift != true)
    }

    /// New Local Workspace is dispatched before New Pane (Auto Layout), so a shared
    /// default would make the pane action unreachable. No other action may default
    /// to New Local Workspace's keystroke, in either catalog.
    @Test func noOtherActionSharesTheDefault() {
        let appDefault = KeyboardShortcutSettings.Action.newLocalWorkspace.defaultShortcut
        let appClashes = KeyboardShortcutSettings.Action.allCases.filter {
            $0 != .newLocalWorkspace && $0.defaultShortcut == appDefault
        }
        #expect(appClashes.isEmpty, "app catalog: \(appClashes)")
        #expect(KeyboardShortcutSettings.Action.newPaneAutoLayout.defaultShortcut != appDefault)

        let settingsDefault = ShortcutAction.newLocalWorkspace.defaultStroke
        let settingsClashes = ShortcutAction.allCases.filter {
            $0 != .newLocalWorkspace && $0.defaultStroke == settingsDefault
        }
        #expect(settingsClashes.isEmpty, "settings catalog: \(settingsClashes)")
    }

    /// At factory defaults each keystroke reaches its own action: ⌃⌘N is New Pane
    /// (Auto Layout) and not New Local Workspace, and ⌃⌥⌘N is the reverse.
    @Test func eachDefaultKeystrokeMatchesOnlyItsOwnAction() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            func keyDown(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
                try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: "n",
                    charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45
                ))
            }
            let controlCommandN = try keyDown([.control, .command])
            #expect(appDelegate.matchConfiguredShortcut(event: controlCommandN, action: .newPaneAutoLayout))
            #expect(!appDelegate.matchConfiguredShortcut(event: controlCommandN, action: .newLocalWorkspace))

            let controlOptionCommandN = try keyDown([.control, .option, .command])
            #expect(appDelegate.matchConfiguredShortcut(event: controlOptionCommandN, action: .newLocalWorkspace))
            #expect(!appDelegate.matchConfiguredShortcut(event: controlOptionCommandN, action: .newPaneAutoLayout))
        }
    }
}
