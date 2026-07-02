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
/// through the same removal path the real window-close flow uses, including
/// per-window Dock teardown.
extension AppDelegate {
    @discardableResult
    func registerMainWindowContextForTesting(
        windowId: UUID = UUID(),
        tabManager: TabManager,
        cmuxConfigStore: CmuxConfigStore? = nil,
        fileExplorerState: FileExplorerState? = nil
    ) -> UUID {
        tabManager.windowId = windowId
        mainWindowContexts[ObjectIdentifier(tabManager)] = MainWindowContext(
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore,
            window: nil
        )
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
        // resolution. Preserve it across the teardown.
        let previousActive = TerminalController.shared.activeTabManagerForCallerNotification()
        mainWindowContexts.values.filter { $0.windowId == windowId }.forEach { discardOrphanedMainWindowContext($0, allowWindowlessFallback: true) }
        TerminalController.shared.setActiveTabManager(previousActive)
    }
}
