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

    func testGroupRootBoundaryInGroupLanePlansLastSlotInsideGroup() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 121))
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .bottom))
        XCTAssertEqual(plan.indicatorScope, .group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 3)
        XCTAssertFalse(usesTopLevelRows)
        XCTAssertEqual(explicitGroupId, fixture.groupId)
    }

    func testGroupRootBoundaryInRootLanePlansRootSlotAfterGroup() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 121))
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 2)
        XCTAssertTrue(usesTopLevelRows)
        XCTAssertNil(explicitGroupId)
    }

    func testPhysicalGapAfterLastGroupChildUsesHorizontalLane() throws {
        let fixture = reorderFixture()

        let groupLanePlan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 116))
        ))
        let rootLanePlan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 116))
        ))

        XCTAssertEqual(groupLanePlan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .bottom))
        XCTAssertEqual(groupLanePlan.indicatorScope, .group(fixture.groupId))
        XCTAssertEqual(rootLanePlan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        XCTAssertEqual(rootLanePlan.indicatorScope, .topLevel)
    }

    func testRootLaneOverExpandedGroupHeaderUsesGroupBlockBoundary() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 60))
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 1)
        XCTAssertTrue(usesTopLevelRows)
        XCTAssertNil(explicitGroupId)
    }

    func testRootLaneInsideGroupChildPlansRootSlotAfterGroup() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 90))
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 2)
        XCTAssertTrue(usesTopLevelRows)
        XCTAssertNil(explicitGroupId)
    }

    func testCrossWindowRootLaneAfterGroupCarriesResolvedTopLevelInsertion() throws {
        let fixture = reorderFixture()
        let foreignWorkspaceId = UUID()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 2, y: 90),
                draggedWorkspaceId: foreignWorkspaceId,
                foreignDraggedIsPinned: false
            )
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .crossWindow(let insertionIndex) = plan.action else {
            XCTFail("Expected cross-window plan")
            return
        }
        XCTAssertEqual(insertionIndex, 2)
    }

    func testGroupedChildRootLaneAfterOwnGroupStillPlansPromotion() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 90), draggedWorkspaceId: fixture.child)
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 2)
        XCTAssertTrue(usesTopLevelRows)
        XCTAssertNil(explicitGroupId)
    }

    func testPinnedGroupedChildPromotedToRootClampsToPinnedTier() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 2, y: 90),
                draggedWorkspaceId: fixture.child,
                pinnedWorkspaceIds: [fixture.child]
            )
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .top))
        XCTAssertEqual(plan.indicatorScope, .topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 1)
        XCTAssertTrue(usesTopLevelRows)
        XCTAssertNil(explicitGroupId)
    }

    func testGroupHeaderGroupLanePlansFirstSlotInGroup() throws {
        let fixture = reorderFixture()

        let plan = try XCTUnwrap(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 70))
        ))

        XCTAssertEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        XCTAssertEqual(plan.indicatorScope, .group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            XCTFail("Expected local reorder plan")
            return
        }
        XCTAssertEqual(targetIndex, 2)
        XCTAssertFalse(usesTopLevelRows)
        XCTAssertEqual(explicitGroupId, fixture.groupId)
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

    private struct ReorderFixture {
        let rootBefore = UUID()
        let anchor = UUID()
        let child = UUID()
        let rootAfter = UUID()
        let dragged = UUID()
        let groupId = UUID()

        func request(
            point: CGPoint,
            draggedWorkspaceId: UUID? = nil,
            foreignDraggedIsPinned: Bool? = nil,
            pinnedWorkspaceIds: Set<UUID> = []
        ) -> SidebarWorkspaceReorderDropRequest {
            SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedWorkspaceId ?? dragged,
                foreignDraggedIsPinned: foreignDraggedIsPinned,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootBefore, isPinned: pinnedWorkspaceIds.contains(rootBefore), groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: anchor, isPinned: pinnedWorkspaceIds.contains(anchor), groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: child, isPinned: pinnedWorkspaceIds.contains(child), groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootAfter, isPinned: pinnedWorkspaceIds.contains(rootAfter), groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: pinnedWorkspaceIds.contains(dragged), groupId: nil)
                ],
                groups: [
                    SidebarWorkspaceReorderGroupSnapshot(id: groupId, anchorWorkspaceId: anchor, isPinned: false)
                ],
                targets: [
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: rootBefore,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 0, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: anchor,
                        groupId: groupId,
                        isGroupHeader: true,
                        frame: CGRect(x: 0, y: 40, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: child,
                        groupId: groupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 12, y: 80, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: rootAfter,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: dragged,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 160, width: 180, height: 32)
                    )
                ],
                memberIndent: 12
            )
        }
    }

    private func reorderFixture() -> ReorderFixture {
        ReorderFixture()
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
