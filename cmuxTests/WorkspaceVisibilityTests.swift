import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceVisibilityTests: XCTestCase {
    func testHiddenWorkspacesAreExcludedAndUnhidingRestoresStoredOrder() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, second.id, third.id])
        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: false))
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, second.id, third.id])
        XCTAssertTrue(manager.hiddenWorkspaceTabs.isEmpty)
    }

    func testHidingFocusedWorkspaceSelectsNextVisibleWorkspace() throws {
        let manager = TabManager()
        _ = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        manager.selectWorkspace(second)

        XCTAssertEqual(manager.selectedTabId, second.id)
        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        XCTAssertEqual(manager.selectedTabId, third.id)
        XCTAssertFalse(third.isHidden)
    }

    func testHidingLastWorkspaceSelectsNearestPreviousVisibleWorkspace() throws {
        let manager = TabManager()
        _ = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        manager.selectWorkspace(third)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: third.id, hidden: true))

        XCTAssertEqual(manager.selectedTabId, second.id)
        XCTAssertFalse(second.isHidden)
    }

    func testWorkspaceCycleFromHiddenSelectionUsesAdjacentVisibleWorkspace() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        manager.selectedTabId = second.id
        manager.selectNextTab()
        XCTAssertEqual(manager.selectedTabId, third.id)

        manager.selectedTabId = second.id
        manager.selectPreviousTab()
        XCTAssertEqual(manager.selectedTabId, first.id)
    }

    func testCannotHideLastVisibleWorkspace() throws {
        let manager = TabManager()
        let onlyWorkspace = try XCTUnwrap(manager.tabs.first)

        XCTAssertFalse(manager.setWorkspaceHidden(tabId: onlyWorkspace.id, hidden: true))
        XCTAssertFalse(onlyWorkspace.isHidden)
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [onlyWorkspace.id])
        XCTAssertEqual(manager.selectedTabId, onlyWorkspace.id)
    }

    func testCannotDetachLastVisibleWorkspaceWhenHiddenWorkspacesRemain() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        XCTAssertFalse(manager.canCloseWorkspace(first, allowPinned: true))
        XCTAssertNil(manager.detachWorkspace(tabId: first.id))
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
    }

    func testSessionSnapshotRestoresHiddenWorkspaceState() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        first.setCustomTitle("First")
        let second = manager.addWorkspace(select: false)
        second.setCustomTitle("Second")
        let third = manager.addWorkspace(select: false)
        third.setCustomTitle("Third")

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.map { $0.customTitle ?? "" }, ["First", "Second", "Third"])
        XCTAssertFalse(restored.tabs[0].isHidden)
        XCTAssertTrue(restored.tabs[1].isHidden)
        XCTAssertFalse(restored.tabs[2].isHidden)
        XCTAssertEqual(restored.visibleWorkspaceTabs.map { $0.customTitle ?? "" }, ["First", "Third"])
    }

    func testSetWorkspaceHiddenResolvesLiveWorkspaceAfterSessionRestore() throws {
        let manager = TabManager()
        _ = try XCTUnwrap(manager.tabs.first)
        let staleSecond = manager.addWorkspace(select: false)
        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        manager.restoreSessionSnapshot(snapshot)
        let liveSecond = try XCTUnwrap(manager.tabs.first { $0.id == staleSecond.id })
        XCTAssertFalse(liveSecond === staleSecond)

        XCTAssertTrue(manager.setWorkspaceHidden(staleSecond, hidden: true))

        XCTAssertTrue(liveSecond.isHidden)
        XCTAssertFalse(staleSecond.isHidden)
    }

    func testHiddenWorkspacesStayInNavigationHistory() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        manager.selectWorkspace(second)
        manager.selectWorkspace(first)
        manager.selectWorkspace(second)
        manager.selectWorkspace(third)
        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        manager.navigateBack()
        XCTAssertEqual(manager.selectedTabId, first.id)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: false))
        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, second.id)
    }

    func testReorderVisibleWorkspaceByDeltaSkipsHiddenWorkspaces() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let fourth = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        XCTAssertTrue(manager.reorderVisibleWorkspace(tabId: fourth.id, byVisibleDelta: -1))

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, fourth.id, third.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, fourth.id, third.id])
    }

    func testReorderVisibleWorkspacePreservesHiddenSlots() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        XCTAssertTrue(manager.reorderVisibleWorkspace(tabId: third.id, byVisibleDelta: -1))

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [third.id, first.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, second.id, first.id])
    }

    func testReorderVisibleWorkspaceToVisibleIndexUsesVisibleSnapshot() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let fourth = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: third.id, hidden: true))
        XCTAssertTrue(
            manager.reorderVisibleWorkspace(
                tabId: fourth.id,
                toVisibleIndex: 1,
                visibleWorkspaceIds: [first.id, second.id, fourth.id]
            )
        )

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, fourth.id, second.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [third.id])
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, fourth.id, third.id, second.id])
    }

    func testMoveVisibleWorkspacesToTopPreservesHiddenSlots() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let fourth = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        XCTAssertTrue(manager.moveVisibleWorkspacesToTop([fourth.id]))

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [fourth.id, first.id, third.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [fourth.id, second.id, first.id, third.id])
    }

    func testMoveTabsToTopUsesVisibleWorkspaceOrder() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let fourth = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        manager.moveTabsToTop([third.id, fourth.id])

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [third.id, fourth.id, first.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, second.id, fourth.id, first.id])
    }

    func testReorderVisibleWorkspaceBeforeAfterUsesVisibleTargets() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)
        let fourth = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        XCTAssertTrue(manager.reorderVisibleWorkspace(tabId: first.id, after: third.id))

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [third.id, first.id, fourth.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, second.id, first.id, fourth.id])

        XCTAssertTrue(manager.reorderVisibleWorkspace(tabId: fourth.id, before: first.id))

        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [third.id, fourth.id, first.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [third.id, second.id, fourth.id, first.id])
    }

    func testReorderVisibleWorkspaceRejectsHiddenSourceOrTarget() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)
        let third = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))

        XCTAssertFalse(manager.reorderVisibleWorkspace(tabId: second.id, after: third.id))
        XCTAssertFalse(manager.reorderVisibleWorkspace(tabId: first.id, before: second.id))
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(manager.hiddenWorkspaceTabs.map(\.id), [second.id])
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, second.id, third.id])
    }

    func testSelectWorkspaceRevealingIfNeededUnhidesBeforeSelection() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace(select: false)

        XCTAssertTrue(manager.setWorkspaceHidden(tabId: second.id, hidden: true))
        XCTAssertEqual(manager.selectedTabId, first.id)

        XCTAssertTrue(manager.selectWorkspaceRevealingIfNeeded(tabId: second.id))

        XCTAssertFalse(second.isHidden)
        XCTAssertEqual(manager.selectedTabId, second.id)
        XCTAssertEqual(manager.visibleWorkspaceTabs.map(\.id), [first.id, second.id])
    }
}
