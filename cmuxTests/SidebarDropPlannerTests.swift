import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class SidebarDropPlannerTests: XCTestCase {
    func testNoIndicatorForNoOpEdges() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: first,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: nil,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
    }

    func testNoIndicatorWhenOnlyOneTabExists() {
        let only = UUID()
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: nil,
                tabIds: [only],
                pinnedTabIds: []
            )
        )
        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: only,
                targetTabId: only,
                tabIds: [only],
                pinnedTabIds: []
            )
        )
    }

    func testIndicatorAppearsForRealMoveToEnd() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: second,
            targetTabId: nil,
            tabIds: tabIds,
            pinnedTabIds: []
        )
        XCTAssertEqual(indicator?.tabId, nil)
        XCTAssertEqual(indicator?.edge, .bottom)
    }

    func testTargetIndexForMoveToEndFromMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let index = SidebarDropPlanner.targetIndex(
            draggedTabId: second,
            targetTabId: nil,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: tabIds,
            pinnedTabIds: []
        )
        XCTAssertEqual(index, 2)
    }

    func testNoIndicatorForSelfDropInMiddle() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: second,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: []
            )
        )
    }

    func testPointerEdgeTopCanSuppressNoOpWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: first,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: [],
                pointerY: 2,
                targetHeight: 40
            )
        )
    }

    func testPointerEdgeBottomAllowsMoveWhenDraggingFirstOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: first,
            targetTabId: second,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 38,
            targetHeight: 40
        )
        XCTAssertEqual(indicator?.tabId, third)
        XCTAssertEqual(indicator?.edge, .top)
        XCTAssertEqual(
            SidebarDropPlanner.targetIndex(
                draggedTabId: first,
                targetTabId: second,
                indicator: indicator,
                tabIds: tabIds,
                pinnedTabIds: []
            ),
            1
        )
    }

    func testEquivalentBoundaryInputsResolveToSingleCanonicalIndicator() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        let fromBottomOfFirst = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: first,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 38,
            targetHeight: 40
        )
        let fromTopOfSecond = SidebarDropPlanner.indicator(
            draggedTabId: third,
            targetTabId: second,
            tabIds: tabIds,
            pinnedTabIds: [],
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(fromBottomOfFirst?.tabId, second)
        XCTAssertEqual(fromBottomOfFirst?.edge, .top)
        XCTAssertEqual(fromTopOfSecond?.tabId, second)
        XCTAssertEqual(fromTopOfSecond?.edge, .top)
    }

    func testPointerEdgeBottomSuppressesNoOpWhenDraggingLastOverSecond() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let tabIds = [first, second, third]

        XCTAssertNil(
            SidebarDropPlanner.indicator(
                draggedTabId: third,
                targetTabId: second,
                tabIds: tabIds,
                pinnedTabIds: [],
                pointerY: 38,
                targetHeight: 40
            )
        )
    }

    func testIndicatorSnapsUnpinnedDropToFirstUnpinnedBoundaryWhenHoveringPinnedWorkspace() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let tabIds = [pinnedA, pinnedB, unpinnedA, unpinnedB]
        let pinnedIds: Set<UUID> = [pinnedA, pinnedB]

        let indicator = SidebarDropPlanner.indicator(
            draggedTabId: unpinnedB,
            targetTabId: pinnedA,
            tabIds: tabIds,
            pinnedTabIds: pinnedIds,
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(indicator?.tabId, unpinnedA)
        XCTAssertEqual(indicator?.edge, .top)
    }

    func testTargetIndexSnapsUnpinnedDropToFirstUnpinnedBoundaryWhenHoveringPinnedWorkspace() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let tabIds = [pinnedA, pinnedB, unpinnedA, unpinnedB]
        let pinnedIds: Set<UUID> = [pinnedA, pinnedB]

        let targetIndex = SidebarDropPlanner.targetIndex(
            draggedTabId: unpinnedB,
            targetTabId: pinnedA,
            indicator: SidebarDropIndicator(tabId: pinnedA, edge: .top),
            tabIds: tabIds,
            pinnedTabIds: pinnedIds
        )

        XCTAssertEqual(targetIndex, 2)
    }

    // MARK: - Cross-window insertion (drag a workspace into another window)

    func testCrossWindowInsertionAppendsWhenDroppingOnEmptyArea() {
        let a = UUID()
        let b = UUID()
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: nil,
            draggedIsPinned: false,
            indicator: nil,
            tabIds: [a, b],
            pinnedTabIds: []
        )

        XCTAssertEqual(result.insertionIndex, 2)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: nil, edge: .bottom))
    }

    func testCrossWindowInsertionTopEdgeInsertsBeforeTarget() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: b,
            draggedIsPinned: false,
            indicator: nil,
            tabIds: [a, b, c],
            pinnedTabIds: [],
            pointerY: 2,
            targetHeight: 40
        )

        XCTAssertEqual(result.insertionIndex, 1)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: b, edge: .top))
    }

    func testCrossWindowInsertionBottomEdgeInsertsAfterTarget() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: b,
            draggedIsPinned: false,
            indicator: nil,
            tabIds: [a, b, c],
            pinnedTabIds: [],
            pointerY: 38,
            targetHeight: 40
        )

        XCTAssertEqual(result.insertionIndex, 2)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: c, edge: .top))
    }

    func testCrossWindowInsertionClampsUnpinnedWorkspaceBelowPinnedRegion() {
        let pinnedA = UUID()
        let pinnedB = UUID()
        let unpinned = UUID()
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: pinnedA,
            draggedIsPinned: false,
            indicator: SidebarDropIndicator(tabId: pinnedA, edge: .top),
            tabIds: [pinnedA, pinnedB, unpinned],
            pinnedTabIds: [pinnedA, pinnedB]
        )

        // An unpinned workspace cannot land above the two pinned rows.
        XCTAssertEqual(result.insertionIndex, 2)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: unpinned, edge: .top))
    }

    func testCrossWindowInsertionClampsPinnedWorkspaceToFrontWhenNoExistingPins() {
        let a = UUID()
        let b = UUID()
        // Drop a pinned workspace into the empty area of a window with no pins.
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: nil,
            draggedIsPinned: true,
            indicator: nil,
            tabIds: [a, b],
            pinnedTabIds: []
        )

        // It cannot sit below the unpinned rows — clamp to the front.
        XCTAssertEqual(result.insertionIndex, 0)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: a, edge: .top))
    }

    func testCrossWindowInsertionClampsPinnedWorkspaceIntoPinnedRegion() {
        let pinnedA = UUID()
        let unpinnedA = UUID()
        let unpinnedB = UUID()
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: unpinnedB,
            draggedIsPinned: true,
            indicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
            tabIds: [pinnedA, unpinnedA, unpinnedB],
            pinnedTabIds: [pinnedA]
        )

        // A pinned workspace cannot land below the single pinned row.
        XCTAssertEqual(result.insertionIndex, 1)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: unpinnedA, edge: .top))
    }

    func testCrossWindowInsertionRecoversIndicatorPositionAtDropTime() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // At drop time the delegate replays the indicator it already showed.
        let result = SidebarDropPlanner.crossWindowInsertion(
            targetTabId: b,
            draggedIsPinned: false,
            indicator: SidebarDropIndicator(tabId: c, edge: .top),
            tabIds: [a, b, c],
            pinnedTabIds: []
        )

        XCTAssertEqual(result.insertionIndex, 2)
        XCTAssertEqual(result.indicator, SidebarDropIndicator(tabId: c, edge: .top))
    }

}


