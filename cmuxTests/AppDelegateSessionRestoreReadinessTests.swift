import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression guard for https://github.com/manaflow-ai/cmux/issues/2751.
//
// `AppDelegate.didCompleteInitialSessionRestore` is the readiness signal that
// gates the v2 control pre-mint pass (`TerminalController.v2RefreshKnownRefs()`
// and its `drag_surface_to_split` twin `controlSidebarRefreshKnownRefs()`):
// those skip the pre-mint while a session restore is pending or in flight so
// they never enumerate a half-built window/tab tree (the EXC_BAD_ACCESS the
// issue reported). The signal is the conjunction of two lifecycle flags:
//
//     didAttemptStartupSessionRestore && !isApplyingSessionRestore
//
// Draft 1 of the fix gated on a flag that could be TRUE before the primary
// restore actually ran on the deferred-signing-secret path, reopening the crash
// window. This test locks the four flag combinations so the signal can only be
// TRUE when restore has truly settled. It reads two Bools, so no real window or
// tab tree is needed and the crash itself (which requires a half-built tree) is
// intentionally not reproduced here.
@Suite(.serialized)
@MainActor
struct AppDelegateSessionRestoreReadinessTests {
    @Test
    func signalIsFalseBeforeRestoreIsAttempted() {
        let previousApp = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        appDelegate.didAttemptStartupSessionRestore = false
        appDelegate.isApplyingSessionRestore = false
        // Pre-attempt / deferred-signing-secret window: nothing has decided to
        // restore yet, so enumerating the tree must be skipped.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }

    @Test
    func signalIsFalseWhileRestoreIsInFlight() {
        let previousApp = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        appDelegate.didAttemptStartupSessionRestore = true
        appDelegate.isApplyingSessionRestore = true
        // restoreSessionSnapshot is mutating a tab manager in place; the tree is
        // half-built, so the pre-mint pass must be skipped.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }

    @Test
    func signalIsTrueOnceRestoreHasSettled() {
        let previousApp = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        appDelegate.didAttemptStartupSessionRestore = true
        appDelegate.isApplyingSessionRestore = false
        // completeSessionRestoreOperation has cleared the in-flight flag: the
        // tree is stable and safe to enumerate.
        #expect(appDelegate.didCompleteInitialSessionRestore == true)
    }

    @Test
    func signalIsFalseWhenApplyingWithoutAttemptFlag() {
        let previousApp = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        appDelegate.didAttemptStartupSessionRestore = false
        appDelegate.isApplyingSessionRestore = true
        // Defensive: any restore-in-flight state must read FALSE regardless of
        // the attempt flag, so the guard can never enumerate a mutating tree.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }
}

// Regression guard for https://github.com/manaflow-ai/cmux/issues/5757.
//
// `controlResolveOnMain` gates the full-tree `v2RefreshKnownRefs()` pass on
// `needsHandleTopologyRefresh`. Repeated calls when the window/tab topology
// hasn't changed must skip rescanning the tree to prevent freezing the MainActor
// during heavy agent load.
@Suite(.serialized)
@MainActor
struct TerminalControllerControlResolveTests {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    @Test
    func repeatedControlResolveOnMainSkipsRescanWhenTopologyUnchanged() throws {
        _ = NSApplication.shared
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer { AppDelegate.shared = previousApp }

        // Session restore settled: readiness allows v2RefreshKnownRefs to proceed
        app.didAttemptStartupSessionRestore = true
        app.isApplyingSessionRestore = false

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        let manager = TabManager()
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        window.makeKeyAndOrderFront(nil)
        TerminalController.shared.setActiveTabManager(manager)

        let initialWorkspace = Workspace()
        manager.tabs = [initialWorkspace]

        // Reset topology refresh state so initial scan can claim it
        TerminalController.shared.invalidateSocketHandleTopologyRefresh()
        #expect(TerminalController.shared.controlCommandCoordinator.needsHandleTopologyRefresh)

        // First call: scans topology, mints initial workspace ref, marks refresh completed
        TerminalController.shared.controlResolveOnMain { _ in }
        #expect(!TerminalController.shared.controlCommandCoordinator.needsHandleTopologyRefresh)
        #expect(TerminalController.shared.v2ExistingHandleRef(kind: .workspace, uuid: initialWorkspace.id) != nil)

        // Add a second workspace directly to manager without posting a topology invalidation
        let secondWorkspace = Workspace()
        manager.tabs.append(secondWorkspace)

        // Second call: topology has not changed (gate closed).
        // Must skip rescan, so secondWorkspace is NOT minted.
        TerminalController.shared.controlResolveOnMain { _ in }
        #expect(!TerminalController.shared.controlCommandCoordinator.needsHandleTopologyRefresh)
        #expect(TerminalController.shared.v2ExistingHandleRef(kind: .workspace, uuid: secondWorkspace.id) == nil)

        // Invalidate topology (mirroring notification when windows/tabs change)
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: app)
        #expect(TerminalController.shared.controlCommandCoordinator.needsHandleTopologyRefresh)

        // Third call: topology was invalidated, so it rescans and mints the second workspace
        TerminalController.shared.controlResolveOnMain { _ in }
        #expect(!TerminalController.shared.controlCommandCoordinator.needsHandleTopologyRefresh)
        #expect(TerminalController.shared.v2ExistingHandleRef(kind: .workspace, uuid: secondWorkspace.id) != nil)
    }
}

