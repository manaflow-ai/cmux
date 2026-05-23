import CoreGraphics
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceDropPlannerTests: XCTestCase {
    func testWorkspaceDropCenterTargetsExistingWorkspace() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 56),
            targets: targets
        )

        XCTAssertEqual(action, .existingWorkspace(second))
    }

    func testWorkspaceDropTopEdgeCreatesWorkspaceBeforeTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 42),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    func testWorkspaceDropBottomEdgeCreatesWorkspaceAfterTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 65),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    func testWorkspaceDropGapCreatesWorkspaceBeforeNextTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 36),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    func testWorkspaceDropAfterLastRowCreatesWorkspaceAtEnd() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 92),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    func testWorkspaceDropKeepsNewWorkspaceAfterPinnedRows() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinned = UUID()
        let targets = workspaceDropTargets([pinnedA, pinnedB, unpinned], pinnedIds: [pinnedA, pinnedB])

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 2),
            targets: targets
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: unpinned, edge: .top)
            )
        )
    }

    func testWorkspaceDropUsesGlobalInsertionIndexForVisibleVirtualizedTargets() {
        let visibleA = UUID()
        let visibleB = UUID()
        let targets = workspaceDropTargets([visibleA, visibleB], startIndex: 50)

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: 65),
            targets: targets,
            workspaceCount: 100,
            pinnedWorkspaceCount: 3
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 52,
                indicator: SidebarDropIndicator(tabId: visibleB, edge: .bottom)
            )
        )
    }

    func testWorkspaceDropClampsVirtualizedTargetsAfterGlobalPinnedRows() {
        let visibleA = UUID()
        let visibleB = UUID()
        let targets = workspaceDropTargets([visibleA, visibleB], startIndex: 8)

        let action = SidebarDropPlanner.workspaceAction(
            for: CGPoint(x: 12, y: -4),
            targets: targets,
            workspaceCount: 100,
            pinnedWorkspaceCount: 10
        )

        XCTAssertEqual(
            action,
            .newWorkspace(
                insertionIndex: 10,
                indicator: SidebarDropIndicator(tabId: visibleB, edge: .bottom)
            )
        )
    }

    private func workspaceDropTargets(
        _ ids: [UUID],
        pinnedIds: Set<UUID> = [],
        startIndex: Int = 0
    ) -> [SidebarDropPlanner.WorkspaceDropTarget] {
        ids.enumerated().map { index, id in
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: id,
                index: startIndex + index,
                isPinned: pinnedIds.contains(id),
                frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
            )
        }
    }
}
