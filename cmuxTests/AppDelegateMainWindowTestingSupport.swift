import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Serializes async app-context tests across suites. Each of these tests swaps
/// process-global state (`AppDelegate.shared`, the active `TabManager`) for its
/// body and suspends mid-flight (socket-worker round-trips, yield loops).
/// `.serialized` only orders tests within one suite, so async tests in
/// different suites can interleave at suspension points and observe each
/// other's globals — a worker-thread socket command then resolves against
/// another test's AppDelegate. Synchronous @MainActor tests are a single
/// uninterruptible actor job (swap and restore included), so only the async
/// ones need this gate.
actor AppContextSerialGate {
    static let shared = AppContextSerialGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private nonisolated func scheduleRelease() {
        Task { await self.release() }
    }

    @MainActor
    static func withExclusiveAppContext<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        await shared.acquire()
        defer { shared.scheduleRelease() }
        return try await body()
    }
}

/// Test-only main-window context seams, kept in the test target per the
/// debug-seam policy and reaching internal AppDelegate state via
/// `@testable import`. Tests register a windowless context and tear it down
/// through the same recoverable path used while SwiftUI replaces a context.
/// Tests that model an authoritative close explicitly forget the resulting
/// route after they finish exercising its recovery behavior.
extension AppDelegate {
    /// Establishes the real window/controller/terminal focus relationship before input probes.
    ///
    /// `makeKeyAndOrderFront` only makes a programmatic window key while the
    /// test host is the active app. The app-host process starts inactive under
    /// `xcodebuild test`, so callers that use a real `createMainWindow()`
    /// window (which cannot be swapped for `KeyStatusTestWindow`) became key
    /// only when an earlier test in the shard happened to activate the app.
    /// Activate explicitly so the terminal focus paths that gate on
    /// `isKeyWindow` are exercised by behavior rather than by test order.
    func focusTerminalForTesting(_ panel: TerminalPanel, workspace: Workspace, in window: NSWindow) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        // Activation and the resulting key-window transition land on later main
        // run-loop turns, and a contended CI runner can take several of them;
        // the pump's one-second default expires before the window goes key.
        guard await AppKitTestEventPump().waitUntil(timeout: .seconds(10), {
            panel.hostedView.uiWindow === window
                && panel.hostedView.surfaceView.window === window
                && panel.hostedView.bounds.width > 1
                && panel.hostedView.bounds.height > 1
                && panel.hostedView.surfaceView.bounds.width > 1
                && panel.hostedView.surfaceView.bounds.height > 1
                && window.isKeyWindow
        }) else { return false }
        noteMainPanelKeyboardFocusIntent(workspaceId: workspace.id, panelId: panel.id, in: window)
        workspace.focusPanel(panel.id, focusIntent: .terminal(.surface))
        return window.makeFirstResponder(panel.hostedView.surfaceView)
            && window.firstResponder === panel.hostedView.surfaceView
            && allowsTerminalKeyboardFocus(workspaceId: workspace.id, panelId: panel.id, in: window)
    }

    @discardableResult
    func registerMainWindowContextForTesting(
        windowId: UUID = UUID(),
        tabManager: TabManager,
        cmuxConfigStore: CmuxConfigStore? = nil,
        fileExplorerState: FileExplorerState? = nil
    ) -> UUID {
        tabManager.windowId = windowId
        let context = MainWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            window: nil,
            workspaceTerminalFontSizeArbiter:
                workspaceTerminalFontSizeArbiter
        )
        mainWindowLifecycleCoordinator.register(
            context,
            lookupKey: ObjectIdentifier(tabManager)
        )
        // Context-based tests exercise observer pipelines without a live phone
        // subscriber; force presence on so the graph attaches (pre-gate
        // behavior). This is deliberately sticky across tests: any test that
        // asserts detached-by-default must set the override itself, as
        // observerPipelinesFollowSubscriberPresence does with save/restore.
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = true
        ensureMobileWorkspaceListObserver(for: tabManager)
        notifyMainWindowContextsDidChange()
        return windowId
    }

    func unregisterMainWindowContextForTesting(windowId: UUID) {
        // Discarding an active context re-points the SHARED controller's
        // active manager (activateMainWindowContext falls back to another
        // context or nil). A test delegate is not the live app delegate, so a
        // finished test would otherwise leave the controller's active manager
        // nil/foreign and pollute concurrently running suites' caller-context
        // resolution. Preserve it across the teardown unless it is the manager
        // being unregistered; in that case the production fallback is correct.
        let previousActive = TerminalController.shared.activeTabManagerForCallerNotification()
        let previousActiveBelongsToRemovedWindow = previousActive.map { active in
            mainWindowContexts.values.contains { $0.windowId == windowId && $0.tabManager === active }
        } ?? false
        let contexts = mainWindowContexts.values.filter { $0.windowId == windowId }
        guard !contexts.isEmpty else {
            forgetRecoverableMainWindowRoute(windowId: windowId)
            if !previousActiveBelongsToRemovedWindow {
                TerminalController.shared.setActiveTabManager(previousActive)
            }
            return
        }
        contexts.forEach {
            discardOrphanedMainWindowContext($0, allowWindowlessFallback: true)
        }
        if !previousActiveBelongsToRemovedWindow {
            TerminalController.shared.setActiveTabManager(previousActive)
        }
    }

    /// Registers a windowless context whose selected workspace holds portal
    /// rendering authority, for fixtures that build a `TerminalSurface` directly.
    /// `setVisibleInUI` and `setActive` fold every request through
    /// `Workspace.portalRenderingEnabled(for:)`, which denies a workspace id that
    /// no registered manager has selected, so a surface built with a made-up
    /// `tabId` is never actually shown or activated. Build the surface with the
    /// returned id and call `tearDown` once the surface is gone.
    func registerLivePortalWorkspaceForTesting() -> (id: UUID, tearDown: @MainActor () -> Void)? {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        guard let workspace = manager.selectedWorkspace else { return nil }
        let windowId = registerMainWindowContextForTesting(tabManager: manager)
        return (workspace.id, { [self] in
            unregisterMainWindowContextForTesting(windowId: windowId)
            forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.finalizeAllWorkspacesForWindowClose()
        })
    }
}

/// A window that reports key status the way the focused main window does in
/// the running app. The app-host test process runs headless under
/// `xcodebuild test` and is usually not the active app, so
/// `makeKeyAndOrderFront` never makes a programmatic window key; whether it
/// does then depends on whether an earlier test happened to activate the app.
/// Terminal focus paths gate on `isKeyWindow` (automatic first-responder
/// apply, focus redraws, deferred focus reapply), so focus tests that do not
/// pin key status pass or fail by test order instead of by behavior.
final class KeyStatusTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
