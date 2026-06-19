import XCTest

import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for `SidebarTabDropIndicatorPredicate().topVisible(forTabId:draggedTabId:dropIndicator:tabIds:)`.
///
/// This predicate is the snapshot the parent computes for each sidebar row to
/// decide whether to draw the drop-line indicator above it. Lifting it out of
/// the row view subtree (per the snapshot-boundary rule) makes it a pure
/// function — these tests cover the resulting branches end-to-end.
final class SidebarTabDropIndicatorPredicateTopVisibleTests: XCTestCase {
    func testReturnsFalseWhenNoDragInProgress() {
        let rowId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId]
            ),
            "An indicator value alone shouldn't trigger the overlay; a drag must be in flight."
        )
    }

    func testReturnsFalseWhenNoIndicator() {
        let rowId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: rowId,
                dropIndicator: nil,
                tabIds: [rowId]
            )
        )
    }

    func testReturnsTrueWhenIndicatorTargetsThisRowTopEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId, draggedId]
            )
        )
    }

    func testReturnsTrueForExternalDragWhenIndicatorTargetsThisRowTopEdge() {
        let rowId = UUID()
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId],
                isExternalDragActive: true
            )
        )
    }

    func testReturnsFalseWhenIndicatorTargetsThisRowBottomEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        // A .bottom indicator on this row paints the indicator above the *next*
        // row, not above this one.
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .bottom),
                tabIds: [rowId, draggedId]
            )
        )
    }

    func testReturnsTrueWhenIndicatorTargetsPreviousRowBottomEdge() {
        let firstId = UUID()
        let middleId = UUID()
        let draggedId = UUID()
        // The visual indicator for "insert between row 0 and row 1" is drawn
        // above row 1, even though the indicator semantically points at row 0
        // with .bottom.
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: middleId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: firstId, edge: .bottom),
                tabIds: [firstId, middleId, draggedId]
            )
        )
    }

    func testReturnsTrueForExternalDragWhenIndicatorTargetsPreviousRowBottomEdge() {
        let firstId = UUID()
        let secondId = UUID()
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: secondId,
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: firstId, edge: .bottom),
                tabIds: [firstId, secondId],
                isExternalDragActive: true
            )
        )
    }

    func testReturnsFalseWhenIndicatorTargetsUnrelatedRow() {
        let rowId = UUID()
        let otherId = UUID()
        let draggedId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: otherId, edge: .top),
                tabIds: [rowId, otherId, draggedId]
            )
        )
    }

    func testReturnsFalseForFirstRowWithBottomIndicatorAboveIt() {
        // The first row has no previous neighbor — a .bottom indicator from a
        // hypothetical previous row can't apply.
        let firstId = UUID()
        let draggedId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: firstId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                tabIds: [firstId, draggedId]
            )
        )
    }

    func testReturnsFalseWhenRowIsNotInTabsList() {
        // Defensive: if the row id isn't in tabIds (stale snapshot), the
        // predicate should return false rather than crashing on the lookup.
        let strayId = UUID()
        let draggedId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: strayId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                tabIds: [UUID(), draggedId]
            )
        )
    }
}

/// Tests for `SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(...)`.
/// The "empty area" sits below the workspace list and shows an indicator when
/// the drop will append at the end of the list.
final class SidebarTabDropIndicatorPredicateEmptyAreaTests: XCTestCase {
    func testReturnsFalseWhenNoDragInProgress() {
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: nil, edge: .top),
                lastTabId: UUID()
            )
        )
    }

    func testReturnsFalseWhenNoIndicator() {
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: nil,
                lastTabId: UUID()
            )
        )
    }

    func testReturnsTrueWhenIndicatorTargetsEndOfList() {
        // tabId == nil means "after the last row" — the empty area shows the
        // indicator regardless of which row was last.
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: nil, edge: .top),
                lastTabId: UUID()
            )
        )
    }

    func testReturnsTrueForExternalDragWhenIndicatorTargetsEndOfList() {
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: nil, edge: .bottom),
                lastTabId: UUID(),
                isExternalDragActive: true
            )
        )
    }

    func testReturnsTrueWhenIndicatorTargetsLastRowBottomEdge() {
        let lastId = UUID()
        XCTAssertTrue(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: lastId, edge: .bottom),
                lastTabId: lastId
            )
        )
    }

    func testReturnsFalseWhenIndicatorTargetsLastRowTopEdge() {
        // A .top indicator on the last row draws the line *above* the last
        // row, not below — so the empty area below it should stay clear.
        let lastId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: lastId, edge: .top),
                lastTabId: lastId
            )
        )
    }

    func testReturnsFalseWhenIndicatorTargetsNonLastRowBottomEdge() {
        let middleId = UUID()
        let lastId = UUID()
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: middleId, edge: .bottom),
                lastTabId: lastId
            )
        )
    }

    func testReturnsFalseWhenListIsEmpty() {
        XCTAssertFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                lastTabId: nil
            )
        )
    }
}

/// Covers the freeze policy that holds `showsModifierShortcutHints` stable
/// for the row whose context menu is open. Without it, pressing/releasing
/// the modifier key while a context menu is up would flip badges on the row
/// sitting behind the menu (visual regression flagged on the lazy-sidebar PR).
final class SidebarShortcutHintFreezePolicyTests: XCTestCase {
    func testReturnsLiveWhenNoRowIsFrozen() {
        let rowId = UUID()
        XCTAssertTrue(
            SidebarShortcutHintFreezePolicy().resolved(
                live: true,
                currentTabId: rowId,
                frozenTabId: nil,
                frozenValue: false
            )
        )
        XCTAssertFalse(
            SidebarShortcutHintFreezePolicy().resolved(
                live: false,
                currentTabId: rowId,
                frozenTabId: nil,
                frozenValue: true
            )
        )
    }

    func testReturnsFrozenWhenCurrentTabMatchesFrozenTab() {
        let rowId = UUID()
        XCTAssertFalse(
            SidebarShortcutHintFreezePolicy().resolved(
                live: true,
                currentTabId: rowId,
                frozenTabId: rowId,
                frozenValue: false
            ),
            "When this row is frozen, the modifier flipping live should not surface."
        )
        XCTAssertTrue(
            SidebarShortcutHintFreezePolicy().resolved(
                live: false,
                currentTabId: rowId,
                frozenTabId: rowId,
                frozenValue: true
            ),
            "Frozen-true must remain true even after the modifier is released."
        )
    }

    func testReturnsLiveForRowsOtherThanTheFrozenOne() {
        let frozenRow = UUID()
        let otherRow = UUID()
        XCTAssertTrue(
            SidebarShortcutHintFreezePolicy().resolved(
                live: true,
                currentTabId: otherRow,
                frozenTabId: frozenRow,
                frozenValue: false
            ),
            "Freeze is per-row; only the row whose menu is open should be pinned."
        )
    }
}
