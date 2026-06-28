import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSidebarSelectionCoalescingTests: XCTestCase {
    func testSidebarWorkspaceSelectionCoalescesToLatestTarget() async {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        manager.requestSidebarWorkspaceSelection(second)
        manager.requestSidebarWorkspaceSelection(third)

        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Sidebar-origin selection should wait briefly so rapid clicks can collapse to the latest target."
        )
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.selectedTabId, third.id)
    }

    func testImmediateWorkspaceSelectionCancelsPendingSidebarSelection() async {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        manager.requestSidebarWorkspaceSelection(second)
        manager.selectWorkspace(third)

        XCTAssertEqual(manager.selectedTabId, third.id)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.selectedTabId, third.id)
        XCTAssertNotEqual(manager.selectedTabId, second.id)
        XCTAssertNotEqual(manager.selectedTabId, first.id)
    }

    func testRequestingCurrentlySelectedWorkspaceCancelsPendingSidebarSelection() async {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false)

        manager.requestSidebarWorkspaceSelection(second)
        manager.requestSidebarWorkspaceSelection(first)

        XCTAssertEqual(manager.selectedTabId, first.id)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(manager.selectedTabId, first.id)
        XCTAssertNotEqual(manager.selectedTabId, second.id)
    }
}
