import AppKit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for remote-tmux mirror lifecycle and focus-neutral topology
/// mutations. Detach coverage uses cached, unstarted control connections so no
/// ssh/tmux ever attaches anywhere. The last-mirror teardown does fire-and-forget
/// the production `ssh -O exit` at cmux's own (nonexistent here) ControlPath
/// socket — a local-only no-op that exits immediately; a test seam to suppress
/// it is exactly the production test-scaffolding cmux policy forbids.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorLifecycleTests {
    private final class CloseVetoDelegate: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    private let ignoreInput: @Sendable (Data) -> Void = { _ in }

    private func mirror(
        controller: RemoteTmuxController,
        manager: TabManager,
        host: RemoteTmuxHost,
        sessionName: String
    ) throws -> RemoteTmuxControlConnection {
        let connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        controller.cacheConnection(connection)
        let mirrored = try controller.mirrorSession(host: host, sessionName: sessionName, into: manager)
        #expect(mirrored)
        return connection
    }

    @Test func detachRemovesMirrorWorkspaceAndStopsConnection() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = try mirror(
            controller: controller,
            manager: manager,
            host: host,
            sessionName: "dev"
        )

        let mirrorWorkspace = try #require(manager.tabs.first { $0.title == "dev" && $0.isRemoteTmuxMirror })
        #expect(manager.tabs.contains { $0.id == mirrorWorkspace.id })

        controller.detach(host: host, sessionName: "dev")

        #expect(!manager.tabs.contains { $0.id == mirrorWorkspace.id })
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs.allSatisfy { !$0.isRemoteTmuxMirror })
        #expect(connection.exited)
    }

    @Test func detachOneOfTwoMirrorsRemovesOnlyThatWorkspace() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        let alpha = try mirror(
            controller: controller,
            manager: manager,
            host: host,
            sessionName: "alpha"
        )
        let beta = try mirror(
            controller: controller,
            manager: manager,
            host: host,
            sessionName: "beta"
        )

        let alphaWorkspace = try #require(manager.tabs.first { $0.title == "alpha" && $0.isRemoteTmuxMirror })
        let betaWorkspace = try #require(manager.tabs.first { $0.title == "beta" && $0.isRemoteTmuxMirror })

        controller.detach(host: host, sessionName: "alpha")

        #expect(!manager.tabs.contains { $0.id == alphaWorkspace.id })
        #expect(manager.tabs.contains { $0.id == betaWorkspace.id })
        #expect(alpha.exited)
        #expect(!beta.exited)
    }

    @Test func nonInteractiveWindowCloseCommitsEvenWhenInteractiveCloseIsVetoed() throws {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager()
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
        let veto = CloseVetoDelegate()
        window.delegate = veto
        var didClose = false
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            didClose = true
        }
        defer {
            NotificationCenter.default.removeObserver(closeObserver)
            window.delegate = nil
            if !didClose { window.close() }
            manager.window = nil
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        #expect(appDelegate.closeMainWindow(windowId: windowId))
        #expect(didClose)
    }

    @Test func nonInteractiveCloseRemovesLastDeadMirrorAndItsWindow() throws {
        _ = NSApplication.shared
        let appDelegate = try #require(AppDelegate.shared)
        let manager = TabManager()
        let localWorkspace = try #require(manager.selectedWorkspace)
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "dev")
        appDelegate.remoteTmuxController.cacheConnection(connection)
        #expect(try appDelegate.remoteTmuxController.mirrorSession(
            host: host,
            sessionName: "dev",
            into: manager
        ))
        let mirrorWorkspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        manager.closeWorkspace(localWorkspace)
        #expect(manager.tabs.map(\.id) == [mirrorWorkspace.id])
        connection.stop()

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
        var didClose = false
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            didClose = true
        }
        defer {
            NotificationCenter.default.removeObserver(closeObserver)
            if !didClose { window.close() }
            manager.window = nil
            if appDelegate.remoteTmuxController.sessionMirror(host: host, sessionName: "dev") != nil {
                appDelegate.remoteTmuxController.detach(host: host, sessionName: "dev")
            }
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let resolution = TerminalController.shared.controlCloseWorkspace(
            routing: ControlRoutingSelectors(
                hasWindowIDParam: true,
                windowID: windowId,
                groupID: nil,
                workspaceID: mirrorWorkspace.id,
                surfaceID: nil,
                paneID: nil
            ),
            workspaceID: mirrorWorkspace.id
        )

        #expect(resolution == .resolved(windowID: windowId))
        #expect(didClose)
        #expect(appDelegate.remoteTmuxController.sessionMirror(host: host, sessionName: "dev") == nil)
    }

    @Test func processExitDrainsFinalPipeBytesBeforeFinishingStream() async throws {
        let pipe = Pipe()
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-process-output-reader-test",
            maxPendingChunks: 8,
            maxPendingBytes: 4096,
            onOverflow: { Issue.record("process output reader overflowed") }
        )
        reader.attach(to: pipe.fileHandleForReading)
        let capture = Task {
            var data = Data()
            for await chunk in reader.stream {
                data.append(chunk)
                reader.release(chunk)
            }
            return data
        }
        defer {
            reader.close()
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let terminalError = Data("no server running on /private/tmp/tmux-501/default\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: terminalError)
        // Model the Process termination callback winning the race against the
        // DispatchSource readability callback. The writer deliberately remains
        // open: processDidExit must drain the bytes already in the pipe itself.
        reader.processDidExit()

        #expect(await capture.value == terminalError)
    }

    @Test func backgroundDisplayPaneCreationPreservesSelectedSurface() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let selectedBefore = try #require(workspace.bonsplitController.selectedTab(inPane: pane)?.id)

        let mirrorPanel = workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 7,
            title: "background",
            focus: false,
            onInput: ignoreInput
        )

        #expect(mirrorPanel != nil)
        #expect(workspace.bonsplitController.focusedPaneId == pane)
        #expect(workspace.bonsplitController.selectedTab(inPane: pane)?.id == selectedBefore)
    }

    @Test func hiddenMirrorWindowStaysHiddenAndNonKeyAcrossBackgroundClose() async throws {
        _ = NSApplication.shared
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        defer { workspace.teardownAllPanels() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        manager.window = window
        defer {
            manager.window = nil
            window.close()
        }

        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let selectedBefore = try #require(workspace.bonsplitController.selectedTab(inPane: pane)?.id)
        _ = try #require(workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 7,
            title: "first mirror",
            focus: false,
            onInput: ignoreInput
        ))
        let closingPanel = try #require(workspace.addRemoteTmuxDisplayPane(
            remotePaneId: 8,
            title: "background mirror",
            focus: false,
            onInput: ignoreInput
        ))
        workspace.bonsplitController.selectTab(selectedBefore)
        window.orderOut(nil)
        await confirmation("hidden mirror window became key", expectedCount: 0) { becameKey in
            let keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: nil
            ) { _ in
                becameKey()
            }
            defer { NotificationCenter.default.removeObserver(keyObserver) }

            #expect(workspace.removeRemoteTmuxDisplayPane(closingPanel.id))
        }

        #expect(workspace.bonsplitController.focusedPaneId == pane)
        #expect(workspace.bonsplitController.selectedTab(inPane: pane)?.id == selectedBefore)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func discoveryPurgesDeadMirrorAndRecreatesItsSession() throws {
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@host")
        var deadManager: TabManager? = TabManager()
        _ = try mirror(
            controller: controller,
            manager: deadManager!,
            host: host,
            sessionName: "dev"
        )
        #expect(controller.sessionMirrors.count == 1)

        // The mirror's window dies without a controller-driven detach: the
        // weak workspace deallocates but the map entry stays. That stale key
        // makes mirrorSessions skip recreation while the dead workspace fails
        // the manager filter, so every re-attach mirrors nothing.
        deadManager = nil

        let target = TabManager()
        controller.cacheConnection(
            RemoteTmuxControlConnection(host: host, sessionName: "dev")
        )
        let workspaceIds = controller.mirrorDiscoveredSessions(
            host: host,
            sessions: [RemoteTmuxSession(
                id: "$1",
                name: "dev",
                windowCount: 1,
                attached: false,
                createdUnix: nil
            )],
            into: target
        )
        #expect(workspaceIds.count == 1)
        #expect(target.tabs.contains { $0.isRemoteTmuxMirror })
        let entry = try #require(controller.sessionMirrors.values.first)
        #expect(entry.mirroredWorkspaceId == workspaceIds.first)
    }

    @Test func failedMirrorAttachKeepsTransportSharedWithLiveMirror() throws {
        let controller = RemoteTmuxController()
        let manager = TabManager()
        let host = RemoteTmuxHost(destination: "user@host")
        _ = try mirror(
            controller: controller,
            manager: manager,
            host: host,
            sessionName: "dev"
        )
        _ = controller.transportRegistry.transport(for: host)
        #expect(controller.transportRegistry.contains(connectionHash: host.connectionHash))

        // An attach that mirrors nothing (e.g. explicitly targeting a window
        // the sessions aren't in) must not kill the ControlMaster the live
        // mirror shares.
        controller.cleanUpTransportAfterFailedMirror(host: host)
        #expect(controller.transportRegistry.contains(connectionHash: host.connectionHash))

        // With no live mirror left, the failed attach owns the transport and
        // must clean it up (the `ssh -O exit` fired here targets cmux's own
        // nonexistent ControlPath socket — a local no-op, per suite policy).
        controller.detach(host: host, sessionName: "dev")
        _ = controller.transportRegistry.transport(for: host)
        controller.cleanUpTransportAfterFailedMirror(host: host)
        #expect(!controller.transportRegistry.contains(connectionHash: host.connectionHash))
    }
}

/// Naming the kill-window confirmation dialog from the live foreground
/// classification (`RemoteTmuxController.mirrorTabActivity`) so it can't lag the
/// tab's own tmux automatic-rename.
@Suite struct RemoteTmuxMirrorTabActivityTests {
    private typealias State = RemoteTmuxControlConnection.PaneForegroundState

    @Test @MainActor func namesTheActivePaneCommand() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: nil
        )
        #expect(activity.hasActiveCommand)
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func prefersTheFocusedPaneWhenSeveralAreActive() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|vim"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: 2
        )
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func namesAnActiveBackgroundPaneWhenTheFocusedOneIsIdle() {
        // Focused pane idle, another pane active → fall past the focused pane to
        // the active one in layout order (the deduped second half of the scan).
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|sleep")],
            paneOrder: [1, 2], activePaneId: 1
        )
        #expect(activity.hasActiveCommand)
        #expect(activity.activeCommandName == "sleep")
    }

    @Test @MainActor func idleWindowHasNoNameAndIsNotActive() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [1: State(rawValue: "0|bash"), 2: State(rawValue: "0|zsh")],
            paneOrder: [1, 2], activePaneId: 1
        )
        #expect(!activity.hasActiveCommand)
        #expect(activity.activeCommandName == nil)
    }

    @Test @MainActor func unclassifiedWindowIsIdle() {
        let activity = RemoteTmuxController.mirrorTabActivity(
            states: [:], paneOrder: [1, 2], activePaneId: nil
        )
        #expect(!activity.hasActiveCommand)
        #expect(activity.activeCommandName == nil)
    }
}
