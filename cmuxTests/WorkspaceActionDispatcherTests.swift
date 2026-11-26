import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceActionDispatcherTests: XCTestCase {
    func testSingleAndSidebarTargetsResolveTheSamePinState() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)

        let singleState = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )
        let sidebarState = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: WorkspaceActionDispatcher.Target(
                    workspaceIds: [workspace.id],
                    anchorWorkspaceId: workspace.id
                )
            )
        )

        XCTAssertEqual(singleState, sidebarState)
        XCTAssertEqual(singleState.pinned, !workspace.isPinned)
    }

    func testPinActionPinsMultipleTargetsFromAnchorState() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try XCTUnwrap(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertTrue(state.pinned)
        XCTAssertEqual(result.targetWorkspaceIds, [second.id, third.id])
        XCTAssertEqual(result.changedWorkspaceIds, [second.id, third.id])
        XCTAssertTrue(second.isPinned)
        XCTAssertTrue(third.isPinned)
        XCTAssertFalse(first.isPinned)
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    func testPinActionUnpinsMultipleTargetsWithExistingOrdering() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setPinned(first, pinned: true)
        manager.setPinned(second, pinned: true)
        manager.setPinned(third, pinned: true)
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try XCTUnwrap(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertFalse(state.pinned)
        XCTAssertEqual(result.targetWorkspaceIds, [second.id, third.id])
        XCTAssertEqual(result.changedWorkspaceIds, [second.id, third.id])
        XCTAssertTrue(first.isPinned)
        XCTAssertFalse(second.isPinned)
        XCTAssertFalse(third.isPinned)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, second.id])
    }

    func testCapturedPinStateKeepsLabelAndActionConsistent() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)
        let state = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )

        manager.setPinned(workspace, pinned: true)
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertTrue(state.pinned)
        XCTAssertTrue(workspace.isPinned)
        XCTAssertTrue(result.changedWorkspaceIds.isEmpty)
    }
}
