import Foundation
import Testing

import CmuxFoundation

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

/// Tests for `SidebarTabDropIndicatorPredicate().topVisible(forTabId:draggedTabId:dropIndicator:tabIds:)`.
///
/// This predicate is the snapshot the parent computes for each sidebar row to
/// decide whether to draw the drop-line indicator above it. Lifting it out of
/// the row view subtree (per the snapshot-boundary rule) makes it a pure
/// function — these tests cover the resulting branches end-to-end.
@Suite struct SidebarTabDropIndicatorPredicateTopVisibleTests {
    @Test func ReturnsFalseWhenNoDragInProgress() {
        let rowId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId]
            ),
            "An indicator value alone shouldn't trigger the overlay; a drag must be in flight."
        )
    }

    @Test func ReturnsFalseWhenNoIndicator() {
        let rowId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: rowId,
                dropIndicator: nil,
                tabIds: [rowId]
            )
        )
    }

    @Test func ReturnsTrueWhenIndicatorTargetsThisRowTopEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        expectTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsThisRowBottomEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        // A .bottom indicator on this row paints the indicator above the *next*
        // row, not above this one.
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .bottom),
                tabIds: [rowId, draggedId]
            )
        )
    }

    @Test func ReturnsTrueWhenIndicatorTargetsPreviousRowBottomEdge() {
        let firstId = UUID()
        let middleId = UUID()
        let draggedId = UUID()
        expectTrue(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: middleId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: firstId, edge: .bottom),
                tabIds: [firstId, middleId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsUnrelatedRow() {
        let rowId = UUID()
        let otherId = UUID()
        let draggedId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: otherId, edge: .top),
                tabIds: [rowId, otherId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseForFirstRowWithBottomIndicatorAboveIt() {
        // The first row has no previous neighbor — a .bottom indicator from a
        // hypothetical previous row can't apply.
        let firstId = UUID()
        let draggedId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: firstId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                tabIds: [firstId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseWhenRowIsNotInTabsList() {
        // Defensive: if the row id isn't in tabIds (stale snapshot), the
        // predicate should return false rather than crashing on the lookup.
        let strayId = UUID()
        let draggedId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().topVisible(
                forTabId: strayId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                tabIds: [UUID(), draggedId]
            )
        )
    }
}

/// Tests for `SidebarTabDropIndicatorPredicate().bottomVisible(forTabId:draggedTabId:dropIndicator:tabIds:)`.
@Suite struct SidebarTabDropIndicatorPredicateBottomVisibleTests {
    @Test func ReturnsFalseWhenNoDragInProgress() {
        let rowId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().bottomVisible(
                forTabId: rowId,
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .bottom),
                tabIds: [rowId]
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsThisRowBottomEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().bottomVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .bottom),
                tabIds: [rowId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsThisRowTopEdge() {
        let rowId = UUID()
        let draggedId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().bottomVisible(
                forTabId: rowId,
                draggedTabId: draggedId,
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .top),
                tabIds: [rowId, draggedId]
            )
        )
    }

    @Test func ReturnsFalseWhenRowIsNotInTabsList() {
        let rowId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().bottomVisible(
                forTabId: rowId,
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: rowId, edge: .bottom),
                tabIds: [UUID()]
            )
        )
    }

    @Test func BottomEdgeBetweenRowsHasExactlyOneVisibleDivider() {
        let previousId = UUID()
        let nextId = UUID()
        let draggedId = UUID()
        let tabIds = [previousId, nextId, draggedId]
        let indicator = SidebarDropIndicator(tabId: previousId, edge: .bottom)
        let predicate = SidebarTabDropIndicatorPredicate()

        expectFalse(
            predicate.topVisible(
                forTabId: previousId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds
            )
        )
        expectFalse(
            predicate.bottomVisible(
                forTabId: previousId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds
            )
        )
        expectTrue(
            predicate.topVisible(
                forTabId: nextId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds
            )
        )
        expectFalse(
            predicate.bottomVisible(
                forTabId: nextId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds
            )
        )
    }

    @Test func GroupEndBottomEdgeRendersOnLastVisibleScopedRow() {
        let lastVisibleId = UUID()
        let draggedId = UUID()
        let indicator = SidebarDropIndicator(tabId: lastVisibleId, edge: .bottom)
        let predicate = SidebarTabDropIndicatorPredicate()

        expectFalse(
            predicate.topVisible(
                forTabId: lastVisibleId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: [lastVisibleId]
            )
        )
        expectTrue(
            predicate.bottomVisible(
                forTabId: lastVisibleId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: [lastVisibleId],
                indicatorScope: .group(UUID())
            )
        )
    }

    @Test func GroupNonEndBottomEdgeStillRendersOnlyAboveNextVisibleRow() {
        let previousId = UUID()
        let nextId = UUID()
        let draggedId = UUID()
        let tabIds = [previousId, nextId, draggedId]
        let indicator = SidebarDropIndicator(tabId: previousId, edge: .bottom)
        let predicate = SidebarTabDropIndicatorPredicate()

        expectFalse(
            predicate.bottomVisible(
                forTabId: previousId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds,
                indicatorScope: .group(UUID())
            )
        )
        expectTrue(
            predicate.topVisible(
                forTabId: nextId,
                draggedTabId: draggedId,
                dropIndicator: indicator,
                tabIds: tabIds
            )
        )
    }
}

/// Tests for `SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(...)`.
/// The "empty area" sits below the workspace list and shows an indicator when
/// the drop will append at the end of the list.
@Suite struct SidebarTabDropIndicatorPredicateEmptyAreaTests {
    @Test func ReturnsFalseWhenNoDragInProgress() {
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: nil,
                dropIndicator: SidebarDropIndicator(tabId: nil, edge: .top),
                lastTabId: UUID()
            )
        )
    }

    @Test func ReturnsFalseWhenNoIndicator() {
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: nil,
                lastTabId: UUID()
            )
        )
    }

    @Test func ReturnsTrueWhenIndicatorTargetsEndOfList() {
        // tabId == nil means "after the last row" — the empty area shows the
        // indicator regardless of which row was last.
        expectTrue(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: nil, edge: .top),
                lastTabId: UUID()
            )
        )
    }

    @Test func ReturnsTrueWhenIndicatorTargetsLastRowBottomEdge() {
        let lastId = UUID()
        expectTrue(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: lastId, edge: .bottom),
                lastTabId: lastId
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsLastRowTopEdge() {
        // A .top indicator on the last row draws the line *above* the last
        // row, not below — so the empty area below it should stay clear.
        let lastId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: lastId, edge: .top),
                lastTabId: lastId
            )
        )
    }

    @Test func ReturnsFalseWhenIndicatorTargetsNonLastRowBottomEdge() {
        let middleId = UUID()
        let lastId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: middleId, edge: .bottom),
                lastTabId: lastId
            )
        )
    }

    @Test func ReturnsFalseWhenListIsEmpty() {
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: UUID(), edge: .bottom),
                lastTabId: nil
            )
        )
    }

    @Test func ScopedGroupAppendDoesNotAlsoRenderInEmptyArea() {
        let lastId = UUID()
        expectFalse(
            SidebarTabDropIndicatorPredicate().emptyAreaTopVisible(
                draggedTabId: UUID(),
                dropIndicator: SidebarDropIndicator(tabId: lastId, edge: .bottom),
                lastTabId: lastId,
                indicatorScope: .group(UUID())
            )
        )
    }
}

/// Covers the freeze policy that holds `showsModifierShortcutHints` stable
/// for the row whose context menu is open. Without it, pressing/releasing
/// the modifier key while a context menu is up would flip badges on the row
/// sitting behind the menu (visual regression flagged on the lazy-sidebar PR).
@Suite struct SidebarShortcutHintFreezePolicyTests {
    @Test func ReturnsLiveWhenNoRowIsFrozen() {
        let rowId = UUID()
        expectTrue(
            SidebarShortcutHintFreezePolicy().resolved(
                live: true,
                currentTabId: rowId,
                frozenTabId: nil,
                frozenValue: false
            )
        )
        expectFalse(
            SidebarShortcutHintFreezePolicy().resolved(
                live: false,
                currentTabId: rowId,
                frozenTabId: nil,
                frozenValue: true
            )
        )
    }

    @Test func ReturnsFrozenWhenCurrentTabMatchesFrozenTab() {
        let rowId = UUID()
        expectFalse(
            SidebarShortcutHintFreezePolicy().resolved(
                live: true,
                currentTabId: rowId,
                frozenTabId: rowId,
                frozenValue: false
            ),
            "When this row is frozen, the modifier flipping live should not surface."
        )
        expectTrue(
            SidebarShortcutHintFreezePolicy().resolved(
                live: false,
                currentTabId: rowId,
                frozenTabId: rowId,
                frozenValue: true
            ),
            "Frozen-true must remain true even after the modifier is released."
        )
    }

    @Test func ReturnsLiveForRowsOtherThanTheFrozenOne() {
        let frozenRow = UUID()
        let otherRow = UUID()
        expectTrue(
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
