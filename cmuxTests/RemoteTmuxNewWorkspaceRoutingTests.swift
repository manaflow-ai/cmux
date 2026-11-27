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
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
    /// selection, so the controller's observable mirror-membership snapshot has to move too.
    @Test func detachingTheSelectedMirrorChangesMirrorMembership() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let controller = RemoteTmuxController()
            let manager = TabManager()
            let before = controller.mirrorMembership.workspaceIDs

            let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
            defer { controller.detach(host: host, sessionName: "esc") }
            let mirrored = controller.mirrorMembership.workspaceIDs
            #expect(mirrored != before)
            #expect(controller.wouldNewWorkspaceSpawnRemote(in: manager))

            controller.detachMirrorWorkspaceKeptOpenLocally(workspaceId: mirrorWorkspace.id)
            #expect(manager.selectedTab?.id == mirrorWorkspace.id)
            #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))
            #expect(controller.mirrorMembership.workspaceIDs != mirrored)
        }
    }

    /// The alert uses fixed product copy and never reproduces untrusted remote output.
    @Test func newSessionFailureAlertDoesNotExposeRemoteErrorText() {
        let create = RemoteTmuxController.newSessionFailureAlertText(
            host: host,
            failure: .create
        )
        let attach = RemoteTmuxController.newSessionFailureAlertText(
            host: host,
            failure: .attach(sessionName: "stuck", removed: false)
        )
        #expect(!create.message.contains("Permission denied"))
        #expect(!create.message.contains("banner"))
        #expect(!attach.message.contains("control stream refused"))
        #expect(!attach.message.contains("stuck"))
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

    /// Plain New Workspace stays local on an active mirror when its caller is
    /// marked local-only, even though the built-in action remains available.
    @Test func localOnlyNewWorkspaceOnActiveMirrorCreatesLocalWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreRouting = RemoteTmuxRoutingFixture.enableNewWorkspaceRouting()
            defer { restoreRouting() }
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
            #expect(appDelegate.performNewWorkspaceAction(
                tabManager: manager,
                debugSource: "test.localOnlyNewWorkspace",
                localOnly: true
            ))

            let createdIds = Set(manager.tabs.map(\.id)).subtracting(tabsBefore)
            #expect(createdIds.count == 1)
            let created = try #require(manager.tabs.first { createdIds.contains($0.id) })
            #expect(!created.isRemoteTmuxMirror)
        }
    }

    /// A configured New Workspace action remains an explicit override on a
    /// mirror. Only the built-in default action is allowed to fall through to
    /// remote tmux routing.
    @Test func configuredNewWorkspaceActionWinsOverRemoteFallbackOnMirror() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cmux-new-workspace-action-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let configURL = root.appendingPathComponent("cmux.json")
            try """
            {
              "actions": {
                "configured-workspace": {
                  "type": "workspace",
                  "title": "Configured Workspace",
                  "workspace": { "name": "Configured Workspace" }
                }
              },
              "ui": { "newWorkspace": { "action": "configured-workspace" } }
            }
            """.write(to: configURL, atomically: true, encoding: .utf8)
            let configStore = CmuxConfigStore(
                globalConfigPath: configURL.path,
                localConfigPath: nil,
                startFileWatchers: false
            )
            configStore.loadAll()

            let manager = TabManager()
            _ = try RemoteTmuxRoutingFixture.mirrorSelectedSession(
                controller: controller,
                host: host,
                sessionName: "configured-host",
                into: manager
            )
            let (windowId, window) = RemoteTmuxRoutingFixture.registerWindowedContext(
                appDelegate: appDelegate,
                manager: manager
            )
            let context = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
            )
            context.cmuxConfigStore = configStore
            defer {
                window.close()
                manager.window = nil
                if controller.sessionMirror(host: host, sessionName: "configured-host") != nil {
                    controller.detach(host: host, sessionName: "configured-host")
                }
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            }

            let before = Set(manager.tabs.map(\.id))
            #expect(appDelegate.performNewWorkspaceAction(
                tabManager: manager,
                debugSource: "test.configured-action"
            ))
            let created = try #require(manager.tabs.first { !before.contains($0.id) })
            #expect(!created.isRemoteTmuxMirror)
            #expect(created.customTitle == "Configured Workspace")
        }
    }

    /// With remote routing disabled, a sidebar empty-area creation on a mirror
    /// follows the ordinary local end-of-list placement instead of taking the
    /// remote placement path and inserting after the selected mirror.
    @Test func emptyAreaOnMirrorWithRoutingDisabledAppendsLocally() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let appDelegate = try #require(AppDelegate.shared)
            let controller = appDelegate.remoteTmuxController
            let defaults = UserDefaults.standard
            let key = SettingCatalog().betaFeatures.remoteTmuxNewWorkspaceOnHost.userDefaultsKey
            let previousValue = defaults.object(forKey: key)
            defer {
                if let previousValue {
                    defaults.set(previousValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            defaults.set(false, forKey: key)

            let restoreSSH = RemoteTmuxRoutingFixture.pinStubSSH("/usr/bin/false")
            defer { restoreSSH() }
            let manager = TabManager()
            let mirrorWorkspace = try mirrorSelectedSession(controller: controller, into: manager)
            _ = manager.addWorkspace(placementOverride: .end)
            manager.selectWorkspace(mirrorWorkspace)
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

            #expect(!controller.wouldNewWorkspaceSpawnRemote(in: manager))
            let before = Set(manager.tabs.map(\.id))
            #expect(appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager))
            let created = try #require(manager.tabs.first { !before.contains($0.id) })
            #expect(!created.isRemoteTmuxMirror)
            #expect(manager.tabs.last?.id == created.id)
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

    /// Stopping a shared host while a routed session is still waiting for reconcile
    /// must consume the request and finish the view teardown instead of stranding the
    /// pending session marker.
    @Test func stoppingAHostCleansUpPendingRoutedSessionState() async {
        let controller = RemoteTmuxController()
        let view = RemoteTmuxViewConnection(host: host, ownerId: "pending-stop-test")
        controller.multiplexedViewsByHost[host.connectionHash] = view
        let sessionName = "cmux-new-pending"
        let key = RemoteTmuxController.connectionKey(host: host, sessionName: sessionName)
        var admitted: Bool?
        controller.pendingMultiplexNewSessionCompletions[key] = { admitted = $0 }

        #expect(controller.stopMultiplexedHost(host: host))
        for _ in 0..<10 where controller.multiplexedViewsByHost[host.connectionHash] != nil {
            await Task.yield()
        }

        #expect(admitted == false)
        #expect(controller.multiplexedViewsByHost[host.connectionHash] == nil)
        #expect(controller.pendingMultiplexNewSessionCompletions[key] == nil)
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
