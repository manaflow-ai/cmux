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

        // The debounce has not fired yet, so the selection is still unchanged.
        XCTAssertEqual(
            manager.selectedTabId,
            first.id,
            "Sidebar-origin selection should wait briefly so rapid clicks can collapse to the latest target."
        )

        await pollUntilSelection(manager, equals: third.id)
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
        await assertSelectionStays(manager, at: third.id)
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
        await assertSelectionStays(manager, at: first.id)
        XCTAssertNotEqual(manager.selectedTabId, second.id)
    }

    /// Deadline-bounded poll: returns the instant the selection reaches `target`,
    /// only spinning up to the deadline so host load can slow a pass but never fail one.
    private func pollUntilSelection(_ manager: TabManager, equals target: UUID?) async {
        for _ in 0..<60 {
            if manager.selectedTabId == target { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Confirms a cancelled pending selection never fires: bails the instant the
    /// selection wrongly changes, otherwise spins past the debounce window.
    private func assertSelectionStays(
        _ manager: TabManager,
        at expected: UUID?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<24 {
            if manager.selectedTabId != expected {
                XCTFail("A cancelled sidebar selection should not fire.", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
