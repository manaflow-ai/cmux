import CoreGraphics
import XCTest

import CmuxFoundation
import CmuxSidebarProviderKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SidebarWorkspaceDropPlannerTests: XCTestCase {
    func testWorkspaceDropTargetCollectionStaysDisabledWhenNoDragIsActive() {
        XCTAssertFalse(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(draggedTabId: nil))
    }

    func testWorkspaceDropTargetCollectionTurnsOnDuringDrag() {
        XCTAssertTrue(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(draggedTabId: UUID()))
    }

    func testWorkspaceDropTargetCollectionTurnsOnDuringBonsplitWorkspaceDrop() {
        XCTAssertTrue(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(
            draggedTabId: nil,
            isBonsplitWorkspaceDropActive: true
        ))
    }

    func testWorkspaceGroupHeaderDropZoneKeepsUsableCenterAtDefaultHeight() {
        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 2, rowHeight: 24))
        XCTAssertTrue(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 12, rowHeight: 24))
        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 22, rowHeight: 24))
    }

    func testWorkspaceGroupHeaderDropZoneKeepsCenterAtCompactHeight() {
        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 2, rowHeight: 20))
        XCTAssertTrue(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 10, rowHeight: 20))
        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropZone.isCenterDrop(locationY: 18, rowHeight: 20))
    }

    func testWorkspaceGroupHeaderCenterDropConsumesSameGroupMember() {
        let workspaceId = UUID()
        let groupId = UUID()
        let anchorId = UUID()

        let action = SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: true,
            draggedWorkspaceId: workspaceId,
            draggedWorkspaceIsPinned: false,
            draggedWorkspaceGroupId: groupId,
            draggedWorkspaceIsGroupAnchor: false,
            targetGroupId: groupId,
            targetAnchorWorkspaceId: anchorId,
            targetAnchorMatchesGroup: true,
            locationY: 12,
            rowHeight: 24
        )

        XCTAssertEqual(action, .noOp)
    }

    func testWorkspaceGroupHeaderCenterDropAddsEligibleWorkspace() {
        let workspaceId = UUID()
        let groupId = UUID()
        let anchorId = UUID()

        let action = SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: true,
            draggedWorkspaceId: workspaceId,
            draggedWorkspaceIsPinned: false,
            draggedWorkspaceGroupId: nil,
            draggedWorkspaceIsGroupAnchor: false,
            targetGroupId: groupId,
            targetAnchorWorkspaceId: anchorId,
            targetAnchorMatchesGroup: true,
            locationY: 12,
            rowHeight: 24
        )

        XCTAssertEqual(action, .addWorkspaceToGroup(workspaceId))
    }

    func testWorkspaceGroupHeaderEdgeDropDoesNotInterceptReorder() {
        let workspaceId = UUID()
        let groupId = UUID()
        let anchorId = UUID()

        let action = SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: true,
            draggedWorkspaceId: workspaceId,
            draggedWorkspaceIsPinned: false,
            draggedWorkspaceGroupId: nil,
            draggedWorkspaceIsGroupAnchor: false,
            targetGroupId: groupId,
            targetAnchorWorkspaceId: anchorId,
            targetAnchorMatchesGroup: true,
            locationY: 2,
            rowHeight: 24
        )

        XCTAssertNil(action)
    }

    func testWorkspaceGroupHeaderBottomEdgeConsumesAdjacentNoOpDrop() {
        let anchorId = UUID()
        let adjacentId = UUID()
        let trailingId = UUID()

        XCTAssertTrue(SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: true,
            draggedWorkspaceId: adjacentId,
            draggedWorkspaceGroupId: nil,
            targetGroupId: UUID(),
            targetAnchorWorkspaceId: anchorId,
            tabIds: [anchorId, adjacentId, trailingId],
            pinnedTabIds: [],
            locationY: 22,
            rowHeight: 24
        ))
    }

    func testWorkspaceGroupHeaderTopEdgeDoesNotConsumeRealReorder() {
        let anchorId = UUID()
        let adjacentId = UUID()
        let trailingId = UUID()

        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: true,
            draggedWorkspaceId: adjacentId,
            draggedWorkspaceGroupId: nil,
            targetGroupId: UUID(),
            targetAnchorWorkspaceId: anchorId,
            tabIds: [anchorId, adjacentId, trailingId],
            pinnedTabIds: [],
            locationY: 2,
            rowHeight: 24
        ))
    }

    func testWorkspaceGroupHeaderCenterDropDoesNotUseEdgeNoOpPolicy() {
        let anchorId = UUID()
        let adjacentId = UUID()
        let trailingId = UUID()

        XCTAssertFalse(SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: true,
            draggedWorkspaceId: adjacentId,
            draggedWorkspaceGroupId: nil,
            targetGroupId: UUID(),
            targetAnchorWorkspaceId: anchorId,
            tabIds: [anchorId, adjacentId, trailingId],
            pinnedTabIds: [],
            locationY: 12,
            rowHeight: 24
        ))
    }

    func testWorkspaceGroupHeaderEdgeDropConsumesSameGroupMember() {
        let anchorId = UUID()
        let memberId = UUID()
        let otherTopLevelId = UUID()
        let groupId = UUID()

        XCTAssertTrue(SidebarWorkspaceGroupHeaderDropPolicy.shouldConsumeNoOpEdgeDrop(
            hasSidebarPayload: true,
            draggedWorkspaceId: memberId,
            draggedWorkspaceGroupId: groupId,
            targetGroupId: groupId,
            targetAnchorWorkspaceId: anchorId,
            tabIds: [anchorId, otherTopLevelId, memberId],
            pinnedTabIds: [],
            locationY: 2,
            rowHeight: 24
        ))
    }

    func testWorkspaceGroupHeaderCenterDropDoesNotInterceptOtherGroupHeader() {
        let workspaceId = UUID()
        let groupId = UUID()
        let anchorId = UUID()

        let action = SidebarWorkspaceGroupHeaderDropPolicy.action(
            hasSidebarPayload: true,
            draggedWorkspaceId: workspaceId,
            draggedWorkspaceIsPinned: false,
            draggedWorkspaceGroupId: UUID(),
            draggedWorkspaceIsGroupAnchor: true,
            targetGroupId: groupId,
            targetAnchorWorkspaceId: anchorId,
            targetAnchorMatchesGroup: true,
            locationY: 12,
            rowHeight: 24
        )

        XCTAssertNil(action)
    }

    func testWorkspaceDropCenterTargetsExistingWorkspace() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 56),
            targets: targets
        )

        XCTAssertEqual(action, .existingWorkspace(second))
    }

    func testWorkspaceDropTopEdgeCreatesWorkspaceBeforeTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
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

        let action = SidebarDropPlanner().workspaceAction(
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

        let action = SidebarDropPlanner().workspaceAction(
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

        let action = SidebarDropPlanner().workspaceAction(
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

        let action = SidebarDropPlanner().workspaceAction(
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

    func testBrowserStackDropCanInsertAtStartOfNextSection() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: openB,
            insertionPosition: 2,
            preferredTargetSectionId: "reading"
            ))

        XCTAssertEqual(move.workspaceId, openB)
        XCTAssertEqual(move.sourceSectionId, "open")
        XCTAssertEqual(move.targetSectionId, "reading")
        XCTAssertEqual(move.targetIndex, 0)
    }

    func testBrowserStackAdjacentTopDropPreservesNextSectionBoundary() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let indicator = ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).sectionBoundaryIndicator(
            draggedWorkspaceId: openB,
            targetWorkspaceId: readingA,
            pointerY: 2,
            targetHeight: 34
        )

        XCTAssertEqual(indicator, SidebarDropIndicator(tabId: readingA, edge: .top))
    }

    func testBrowserStackAdjacentBottomDropPreservesPreviousSectionBoundary() throws {
        let openA = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let indicator = ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).sectionBoundaryIndicator(
            draggedWorkspaceId: readingA,
            targetWorkspaceId: openA,
            pointerY: 32,
            targetHeight: 34
        )

        XCTAssertEqual(indicator, SidebarDropIndicator(tabId: openA, edge: .bottom))
    }

    func testBrowserStackDropBoundaryBottomStaysInPreviousSection() throws {
        let openA = UUID()
        let readingA = UUID()
        let readingB = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingB, sectionId: "reading")
        ]

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: readingB,
            insertionPosition: 1,
            preferredTargetSectionId: "open"
            ))

        XCTAssertEqual(move.workspaceId, readingB)
        XCTAssertEqual(move.sourceSectionId, "reading")
        XCTAssertEqual(move.targetSectionId, "open")
        XCTAssertEqual(move.targetIndex, 1)
    }

    func testBrowserStackDropBoundaryBottomPrefersTargetRowSection() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let readingB = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingB, sectionId: "reading")
        ]

        let preferredSectionId = ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).preferredSectionId(
            targetWorkspaceId: openB,
            indicator: SidebarDropIndicator(tabId: readingA, edge: .top)
        )

        XCTAssertEqual(preferredSectionId, "open")

        let move = try XCTUnwrap(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: readingB,
            insertionPosition: 2,
            preferredTargetSectionId: preferredSectionId
            ))
        XCTAssertEqual(move.workspaceId, readingB)
        XCTAssertEqual(move.sourceSectionId, "reading")
        XCTAssertEqual(move.targetSectionId, "open")
        XCTAssertEqual(move.targetIndex, 2)
    }

    private func workspaceDropTargets(
        _ ids: [UUID],
        pinnedIds: Set<UUID> = []
    ) -> [SidebarDropPlanner.WorkspaceDropTarget] {
        ids.enumerated().map { index, id in
            SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: id,
                isPinned: pinnedIds.contains(id),
                frame: CGRect(x: 0, y: CGFloat(index * 40), width: 180, height: 32)
            )
        }
    }
}
