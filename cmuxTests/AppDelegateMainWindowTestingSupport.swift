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

// `@TaskLocal` storage is type-scoped so the headless replacement applies only
// to the window-creation task that explicitly opts in.
private struct HeadlessMainWindowTaskContext {
    @TaskLocal static var isEnabled = false
}

/// Replaces newly registered main-window content before it is ordered on
/// screen. Routing tests retain the production registration path while
/// avoiding native SwiftUI/Ghostty renderer allocation on CI.
@MainActor
final class HeadlessMainWindowInterceptor: NSObject {
    private weak var appDelegate: AppDelegate?
    private var knownWindowKeys: Set<ObjectIdentifier>
    private var isInvalidated = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        knownWindowKeys = Set(
            appDelegate.mainWindowContexts.values.compactMap(\.window).map(ObjectIdentifier.init)
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowContextsDidChange(_:)),
            name: .mainWindowContextsDidChange,
            object: appDelegate
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    nonisolated static func replacingNewWindowContent<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        try HeadlessMainWindowTaskContext.$isEnabled.withValue(true, operation: operation)
    }

    nonisolated static func replacingNewWindowContent<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await HeadlessMainWindowTaskContext.$isEnabled.withValue(true, operation: operation)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func mainWindowContextsDidChange(_ notification: Notification) {
        guard !isInvalidated, let appDelegate else { return }
        let windows = appDelegate.mainWindowContexts.values.compactMap(\.window)
        let currentWindowKeys = Set(windows.map(ObjectIdentifier.init))
        let newWindowKeys = currentWindowKeys.subtracting(knownWindowKeys)
        knownWindowKeys = currentWindowKeys

        guard HeadlessMainWindowTaskContext.isEnabled else { return }
        for window in windows where newWindowKeys.contains(ObjectIdentifier(window)) {
            window.contentViewController = nil
            let placeholder = NSView(frame: window.contentLayoutRect)
            placeholder.autoresizingMask = [.width, .height]
            window.contentView = placeholder
        }
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
            window: nil,
            workspaceTerminalFontSizeArbiter:
                workspaceTerminalFontSizeArbiter
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
        mainWindowContexts.values.filter { $0.windowId == windowId }.forEach { discardOrphanedMainWindowContext($0, allowWindowlessFallback: true) }
        if !previousActiveBelongsToRemovedWindow {
            TerminalController.shared.setActiveTabManager(previousActive)
        }
    }
}
