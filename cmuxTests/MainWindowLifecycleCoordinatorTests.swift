import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Main window lifecycle coordinator", .serialized)
struct MainWindowLifecycleCoordinatorTests {
    @Test("Frozen orphan retention keeps only the newest configured records")
    func frozenOrphanRetentionKeepsNewestRecords() {
        let coordinator = MainWindowLifecycleCoordinator(
            maximumFrozenOrphanRecords: 2
        )
        let windowIds = (0..<4).map { _ in UUID() }
        var managers: [TabManager] = []
        defer {
            for manager in managers {
                for workspace in manager.tabs {
                    workspace.teardownAllPanels()
                    workspace.teardownRemoteConnection()
                    workspace.owningTabManager = nil
                }
            }
        }

        for windowId in windowIds {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            managers.append(manager)
            let context = AppDelegate.MainWindowContext(
                windowId: windowId,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: nil,
                cmuxConfigStore: nil,
                window: nil,
                workspaceTerminalFontSizeArbiter:
                    WorkspaceTerminalFontSizeArbiter()
            )
            coordinator.register(
                context,
                lookupKey: ObjectIdentifier(manager)
            )
            let route = RecoverableMainWindowRoute(
                windowId: windowId,
                frozenWindowSnapshot: emptyWindowSnapshot(windowId: windowId)
            )
            #expect(coordinator.transitionToOrphaned(route, from: context))
        }

        #expect(coordinator.orphanedRoute(windowId: windowIds[0]) == nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[1]) == nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[2]) != nil)
        #expect(coordinator.orphanedRoute(windowId: windowIds[3]) != nil)
        #expect(coordinator.orphanedRoutes().map(\.windowId) == [windowIds[3], windowIds[2]])
    }

    private func emptyWindowSnapshot(windowId: UUID) -> SessionWindowSnapshot {
        SessionWindowSnapshot(
            windowId: windowId,
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: nil,
                workspaces: []
            ),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }
}
