import CoreGraphics
import Foundation
import Testing

import CmuxFoundation
import CmuxSidebarProviderKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func expectTrue(_ value: Bool, _ message: String? = nil) {
    _ = message
    #expect(value)
}

private func expectFalse(_ value: Bool, _ message: String? = nil) {
    _ = message
    #expect(!value)
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String? = nil) {
    _ = message
    #expect(lhs == rhs)
}

private func expectEqual<T: Equatable>(_ lhs: T?, _ rhs: T, _ message: String? = nil) {
    _ = message
    #expect(lhs == rhs)
}

private func require<T>(_ value: T?, _ message: String? = nil) throws -> T {
    _ = message
    return try #require(value)
}

@Suite struct SidebarWorkspaceDropPlannerTests {
    @Test func WorkspaceDropTargetCollectionStaysDisabledWhenNoDragIsActive() {
        expectFalse(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(draggedTabId: nil))
    }

    @Test func WorkspaceDropTargetCollectionTurnsOnDuringDrag() {
        expectTrue(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(draggedTabId: UUID()))
    }

    @Test func WorkspaceDropTargetCollectionTurnsOnDuringBonsplitWorkspaceDrop() {
        expectTrue(SidebarDropPlanner().shouldCollectWorkspaceDropTargets(
            draggedTabId: nil,
            isBonsplitWorkspaceDropActive: true
        ))
    }

    @Test func GroupRootBoundaryInGroupLanePlansLastSlotInsideGroup() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 120, y: 121))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 3)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func GroupRootBoundaryInRootLanePlansRootSlotAfterGroup() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 121))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func PhysicalGapAfterLastGroupChildUsesHorizontalLane() throws {
        let fixture = reorderFixture()

        let groupLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 120, y: 116))
        ))
        let rootLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 116))
        ))

        expectEqual(groupLanePlan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .bottom))
        expectEqual(groupLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        expectEqual(rootLanePlan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        expectEqual(rootLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
    }

    @Test func AmbiguousGroupBoundaryUsesSidebarMidpoint() throws {
        let fixture = reorderFixture()

        let rootLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 89, y: 121))
        ))
        let groupLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 90, y: 121))
        ))

        expectEqual(rootLanePlan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        expectEqual(rootLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        expectEqual(groupLanePlan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .bottom))
        expectEqual(groupLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
    }

    @Test func GapBetweenVisibleGroupChildrenUsesClosestGroupGap() throws {
        let fixture = multiChildReorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 116))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.childB, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 3)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func LeftGutterBesideVisibleGroupChildUsesGroupGap() throws {
        let fixture = multiChildReorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 90))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.childA, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func LastVisibleGroupChildBottomEdgeUsesHorizontalLane() throws {
        let fixture = multiChildReorderFixture()

        let groupLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 120, y: 136))
        ))
        let rootLanePlan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 136))
        ))

        expectEqual(groupLanePlan.indicator, SidebarDropIndicator(tabId: fixture.childB, edge: .bottom))
        expectEqual(groupLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = groupLanePlan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 4)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
        expectEqual(rootLanePlan.indicator, SidebarDropIndicator(tabId: fixture.childB, edge: .bottom))
        expectEqual(rootLanePlan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let rootTargetIndex, let rootUsesTopLevelRows, let rootExplicitGroupId) = rootLanePlan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(rootTargetIndex, 2)
        expectTrue(rootUsesTopLevelRows)
        #expect(rootExplicitGroupId == nil)
    }

    @Test func RootLaneGapCloserToLastVisibleGroupChildKeepsSharedBoundaryIndicator() throws {
        let fixture = multiChildReorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 154))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.childB, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func CollapsedGroupHeaderGroupLanePlansFirstVisibleGroupSlot() throws {
        let fixture = collapsedGroupReorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 120, y: 56))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func CollapsedGroupHeaderLeftHalfPlansRootSlotAfterGroup() throws {
        let fixture = collapsedGroupReorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 56))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func RootLaneOverExpandedGroupHeaderTopUsesGroupBlockBoundary() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 50))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 1)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func FirstChildLeftGutterPlansFirstGroupSlot() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 90))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func CrossWindowRootLaneAfterGroupCarriesResolvedTopLevelInsertion() throws {
        let fixture = reorderFixture()
        let foreignWorkspaceId = UUID()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 2, y: 121),
                draggedWorkspaceId: foreignWorkspaceId,
                foreignDraggedIsPinned: false
            )
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .crossWindow(
            insertionIndex: let insertionIndex,
            proposedInsertionIndex: let proposedInsertionIndex
        ) = plan.action else {
            Issue.record("Expected cross-window plan")
            return
        }
        expectEqual(insertionIndex, 2)
        expectEqual(proposedInsertionIndex, 2)
    }

    @Test func CrossWindowPinnedClampCarriesUnclampedPointerSlot() throws {
        let fixture = reorderFixture()
        let foreignWorkspaceId = UUID()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 2, y: 1),
                draggedWorkspaceId: foreignWorkspaceId,
                foreignDraggedIsPinned: false,
                pinnedWorkspaceIds: [fixture.rootBefore]
            )
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .crossWindow(
            insertionIndex: let insertionIndex,
            proposedInsertionIndex: let proposedInsertionIndex
        ) = plan.action else {
            Issue.record("Expected cross-window plan")
            return
        }
        expectEqual(insertionIndex, 1)
        expectEqual(proposedInsertionIndex, 0)
    }

    @Test func GroupedChildRootLaneAfterOwnGroupStillPlansPromotion() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 121), draggedWorkspaceId: fixture.child)
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootAfter, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func PinnedGroupedChildPromotedToRootClampsToPinnedTier() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 2, y: 121),
                draggedWorkspaceId: fixture.child,
                pinnedWorkspaceIds: [fixture.child]
            )
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.rootBefore, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.topLevel)
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 0)
        expectTrue(usesTopLevelRows)
        #expect(explicitGroupId == nil)
    }

    @Test func RootSelfDropDoesNotInventIndicator() {
        let fixture = reorderFixture()

        let plan = SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 14, y: 170),
                draggedWorkspaceId: fixture.dragged
            )
        )

        #expect(plan == nil)
    }

    @Test func GroupHeaderCenterGroupLanePlansFirstSlotInGroup() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 56))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func GroupHeaderBottomGroupLanePlansFirstSlotInGroup() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 14, y: 70))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func GroupHeaderBottomLeftHalfStillPlansFirstSlotInGroup() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(point: CGPoint(x: 2, y: 70))
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.anchor, edge: .bottom))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func HeaderChildGapDraggingFirstChildStillShowsFirstGroupSlot() throws {
        let fixture = reorderFixture()

        let plan = try require(SidebarWorkspaceReorderDropResolver().plan(
            for: fixture.request(
                point: CGPoint(x: 14, y: 76),
                draggedWorkspaceId: fixture.child
            )
        ))

        expectEqual(plan.indicator, SidebarDropIndicator(tabId: fixture.child, edge: .top))
        expectEqual(plan.indicatorScope, SidebarWorkspaceReorderDropIndicatorScope.group(fixture.groupId))
        guard case .reorder(let targetIndex, let usesTopLevelRows, let explicitGroupId) = plan.action else {
            Issue.record("Expected local reorder plan")
            return
        }
        expectEqual(targetIndex, 2)
        expectFalse(usesTopLevelRows)
        expectEqual(explicitGroupId, fixture.groupId)
    }

    @Test func WorkspaceDropCenterTargetsExistingWorkspace() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 56),
            targets: targets
        )

        expectEqual(action, SidebarDropPlanner.WorkspaceDropAction.existingWorkspace(second))
    }

    @Test func WorkspaceDropTopEdgeCreatesWorkspaceBeforeTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 42),
            targets: targets
        )

        expectEqual(
            action,
            SidebarDropPlanner.WorkspaceDropAction.newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    @Test func WorkspaceDropBottomEdgeCreatesWorkspaceAfterTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 65),
            targets: targets
        )

        expectEqual(
            action,
            SidebarDropPlanner.WorkspaceDropAction.newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    @Test func WorkspaceDropGapCreatesWorkspaceBeforeNextTarget() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 36),
            targets: targets
        )

        expectEqual(
            action,
            SidebarDropPlanner.WorkspaceDropAction.newWorkspace(
                insertionIndex: 1,
                indicator: SidebarDropIndicator(tabId: second, edge: .top)
            )
        )
    }

    @Test func WorkspaceDropAfterLastRowCreatesWorkspaceAtEnd() {
        let first = UUID()
        let second = UUID()
        let targets = workspaceDropTargets([first, second])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 92),
            targets: targets
        )

        expectEqual(
            action,
            SidebarDropPlanner.WorkspaceDropAction.newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: nil, edge: .bottom)
            )
        )
    }

    @Test func WorkspaceDropKeepsNewWorkspaceAfterPinnedRows() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinned = UUID()
        let targets = workspaceDropTargets([pinnedA, pinnedB, unpinned], pinnedIds: [pinnedA, pinnedB])

        let action = SidebarDropPlanner().workspaceAction(
            for: CGPoint(x: 12, y: 2),
            targets: targets
        )

        expectEqual(
            action,
            SidebarDropPlanner.WorkspaceDropAction.newWorkspace(
                insertionIndex: 2,
                indicator: SidebarDropIndicator(tabId: unpinned, edge: .top)
            )
        )
    }

    @Test func BrowserStackDropCanInsertAtStartOfNextSection() throws {
        let openA = UUID()
        let openB = UUID()
        let readingA = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: openB, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading")
        ]

        let move = try require(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: openB,
            insertionPosition: 2,
            preferredTargetSectionId: "reading"
            ))

        expectEqual(move.workspaceId, openB)
        expectEqual(move.sourceSectionId, "open")
        expectEqual(move.targetSectionId, "reading")
        expectEqual(move.targetIndex, 0)
    }

    @Test func BrowserStackAdjacentTopDropPreservesNextSectionBoundary() throws {
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

        expectEqual(indicator, SidebarDropIndicator(tabId: readingA, edge: .top))
    }

    @Test func BrowserStackAdjacentBottomDropPreservesPreviousSectionBoundary() throws {
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

        expectEqual(indicator, SidebarDropIndicator(tabId: openA, edge: .bottom))
    }

    @Test func BrowserStackDropBoundaryBottomStaysInPreviousSection() throws {
        let openA = UUID()
        let readingA = UUID()
        let readingB = UUID()
        let rows = [
            ExtensionSidebarBrowserStackDropRow(workspaceId: openA, sectionId: "open"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingA, sectionId: "reading"),
            ExtensionSidebarBrowserStackDropRow(workspaceId: readingB, sectionId: "reading")
        ]

        let move = try require(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: readingB,
            insertionPosition: 1,
            preferredTargetSectionId: "open"
            ))

        expectEqual(move.workspaceId, readingB)
        expectEqual(move.sourceSectionId, "reading")
        expectEqual(move.targetSectionId, "open")
        expectEqual(move.targetIndex, 1)
    }

    @Test func BrowserStackDropBoundaryBottomPrefersTargetRowSection() throws {
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

        expectEqual(preferredSectionId, "open")

        let move = try require(ExtensionSidebarBrowserStackDropPlanner(orderedRows: rows).move(
            draggedWorkspaceId: readingB,
            insertionPosition: 2,
            preferredTargetSectionId: preferredSectionId
            ))
        expectEqual(move.workspaceId, readingB)
        expectEqual(move.sourceSectionId, "reading")
        expectEqual(move.targetSectionId, "open")
        expectEqual(move.targetIndex, 2)
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
                ]
            )
        }
    }

    private struct MultiChildReorderFixture {
        let rootBefore = UUID()
        let anchor = UUID()
        let childA = UUID()
        let childB = UUID()
        let rootAfter = UUID()
        let dragged = UUID()
        let groupId = UUID()

        func request(point: CGPoint) -> SidebarWorkspaceReorderDropRequest {
            SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: dragged,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootBefore, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: anchor, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childA, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: childB, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootAfter, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: nil)
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
                        workspaceId: childA,
                        groupId: groupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 12, y: 80, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: childB,
                        groupId: groupId,
                        isGroupHeader: false,
                        frame: CGRect(x: 12, y: 120, width: 168, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: rootAfter,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 160, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: dragged,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 200, width: 180, height: 32)
                    )
                ]
            )
        }
    }

    private struct CollapsedGroupReorderFixture {
        let rootBefore = UUID()
        let anchor = UUID()
        let hiddenChild = UUID()
        let rootAfter = UUID()
        let dragged = UUID()
        let groupId = UUID()

        func request(point: CGPoint) -> SidebarWorkspaceReorderDropRequest {
            SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: dragged,
                workspaces: [
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootBefore, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: anchor, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: hiddenChild, isPinned: false, groupId: groupId),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: rootAfter, isPinned: false, groupId: nil),
                    SidebarWorkspaceReorderWorkspaceSnapshot(id: dragged, isPinned: false, groupId: nil)
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
                        workspaceId: rootAfter,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 80, width: 180, height: 32)
                    ),
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: dragged,
                        groupId: nil,
                        isGroupHeader: false,
                        frame: CGRect(x: 0, y: 120, width: 180, height: 32)
                    )
                ]
            )
        }
    }

    private func reorderFixture() -> ReorderFixture {
        ReorderFixture()
    }

    private func multiChildReorderFixture() -> MultiChildReorderFixture {
        MultiChildReorderFixture()
    }

    private func collapsedGroupReorderFixture() -> CollapsedGroupReorderFixture {
        CollapsedGroupReorderFixture()
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
