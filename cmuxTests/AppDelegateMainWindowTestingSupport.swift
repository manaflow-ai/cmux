import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
        mainWindowContexts.values.filter { $0.windowId == windowId }.forEach { discardOrphanedMainWindowContext($0, allowWindowlessFallback: true) }
    }
}
