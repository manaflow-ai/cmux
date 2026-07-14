import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct SidebarPointerInteractionMonitorTests {
    @Test func frameChangesReconcileStationaryPointerAcrossRemountReorderAndScroll() {
        let monitor = SidebarPointerInteractionMonitor()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstRowId = SidebarWorkspaceRenderItemID.workspace(firstWorkspaceId)
        let secondRowId = SidebarWorkspaceRenderItemID.workspace(secondWorkspaceId)

        monitor.updateFrame(
            CGRect(x: 0, y: 0, width: 200, height: 30),
            for: firstRowId,
            workspaceId: firstWorkspaceId
        )
        monitor.updateFrame(
            CGRect(x: 0, y: 32, width: 200, height: 30),
            for: secondRowId,
            workspaceId: secondWorkspaceId
        )
        monitor.recordPointerLocation(CGPoint(x: 100, y: 15))
        #expect(monitor.hoveredRowId == firstRowId)

        // A lazy remount removes the old row before its replacement reports.
        monitor.removeFrame(for: firstRowId)
        #expect(monitor.hoveredRowId == nil)
        monitor.updateFrame(
            CGRect(x: 0, y: 0, width: 200, height: 30),
            for: firstRowId,
            workspaceId: firstWorkspaceId
        )
        #expect(monitor.hoveredRowId == firstRowId)

        // Reordering/scrolling changes only frame data. No new pointer event is
        // recorded, but the stationary pointer resolves to the row now under it.
        monitor.updateFrame(
            CGRect(x: 0, y: 32, width: 200, height: 30),
            for: firstRowId,
            workspaceId: firstWorkspaceId
        )
        monitor.updateFrame(
            CGRect(x: 0, y: 0, width: 200, height: 30),
            for: secondRowId,
            workspaceId: secondWorkspaceId
        )
        #expect(monitor.hoveredRowId == secondRowId)

        monitor.updateFrame(
            CGRect(x: 0, y: -40, width: 200, height: 30),
            for: secondRowId,
            workspaceId: secondWorkspaceId
        )
        #expect(monitor.hoveredRowId == nil)
    }

    @Test func convertsAppKitBottomLeftPointToSwiftUITopLeftPoint() {
        let point = SidebarPointerInteractionMonitor.swiftUIPoint(
            fromAppKitPoint: CGPoint(x: 45, y: 170),
            viewportBounds: CGRect(x: 5, y: 20, width: 240, height: 200)
        )

        #expect(point == CGPoint(x: 40, y: 50))
    }

    @Test func hitTestingReturnsOnlyRegisteredRowWorkspace() {
        let monitor = SidebarPointerInteractionMonitor()
        let workspaceId = UUID()
        let rowId = SidebarWorkspaceRenderItemID.workspace(workspaceId)
        monitor.updateFrame(
            CGRect(x: 20, y: 40, width: 180, height: 28),
            for: rowId,
            workspaceId: workspaceId
        )

        #expect(monitor.rowId(at: CGPoint(x: 100, y: 54)) == rowId)
        #expect(monitor.middleClickWorkspaceId(at: CGPoint(x: 100, y: 54)) == workspaceId)
        #expect(monitor.rowId(at: CGPoint(x: 10, y: 54)) == nil)
        #expect(monitor.middleClickWorkspaceId(at: CGPoint(x: 100, y: 80)) == nil)
    }

    @Test func menuTrackingReconciliationIgnoresSubmenuEndNotifications() {
        let rootMenu = NSMenu()
        let submenu = NSMenu()
        let item = NSMenuItem(title: "submenu", action: nil, keyEquivalent: "")
        rootMenu.addItem(item)
        rootMenu.setSubmenu(submenu, for: item)

        #expect(SidebarPointerInteractionMonitor.shouldReconcileMenuEnd(object: rootMenu))
        #expect(!SidebarPointerInteractionMonitor.shouldReconcileMenuEnd(object: submenu))
        #expect(!SidebarPointerInteractionMonitor.shouldReconcileMenuEnd(object: nil))
    }
}
