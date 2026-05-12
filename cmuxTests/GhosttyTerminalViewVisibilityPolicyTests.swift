import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testInteractiveGeometryResizeUsesImmediatePortalSyncDecision() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: true
            ),
            "Interactive resize should use the immediate portal sync path"
        )
    }

    func testTerminalTimestampStoreAssignsNewRowsFromScrollbarGrowth() {
        let store = TerminalTimestampStore()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 140)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 3, offset: 0, len: 3),
            at: first,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 2, len: 3),
            at: second,
            markVisibleRows: true
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 2, len: 3)),
            [
                TerminalTimestampVisibleRow(row: 2, timestamp: first),
                TerminalTimestampVisibleRow(row: 3, timestamp: second),
                TerminalTimestampVisibleRow(row: 4, timestamp: second),
            ]
        )
    }

    func testTerminalTimestampVisibleWindowTracksCurrentScrollPosition() {
        let state = TerminalTimestampScrollbarState.visibleWindow(
            total: 100,
            fallbackLen: 3,
            visibleTopRow: 42.25,
            viewportHeight: 25,
            cellHeight: 10
        )

        XCTAssertEqual(state, TerminalTimestampScrollbarState(total: 100, offset: 42, len: 4))
    }

    func testTerminalTimestampStoreDoesNotInventOldRowsDuringUserScroll() {
        let store = TerminalTimestampStore()
        let first = Date(timeIntervalSince1970: 100)
        let userScroll = Date(timeIntervalSince1970: 200)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 8, offset: 5, len: 3),
            at: first,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 8, offset: 0, len: 3),
            at: userScroll,
            markVisibleRows: false
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 8, offset: 0, len: 3)),
            []
        )
        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 8, offset: 5, len: 3)),
            [
                TerminalTimestampVisibleRow(row: 5, timestamp: first),
                TerminalTimestampVisibleRow(row: 6, timestamp: first),
                TerminalTimestampVisibleRow(row: 7, timestamp: first),
            ]
        )
    }

    func testTerminalTimestampStoreMarksNewRowsWithoutBackfillingVisibleScrollback() {
        let store = TerminalTimestampStore()
        let first = Date(timeIntervalSince1970: 100)
        let laterOutput = Date(timeIntervalSince1970: 200)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 8, offset: 5, len: 3),
            at: first,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 10, offset: 0, len: 3),
            at: laterOutput,
            markVisibleRows: false
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 10, offset: 0, len: 3)),
            []
        )
        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 10, offset: 8, len: 2)),
            [
                TerminalTimestampVisibleRow(row: 8, timestamp: laterOutput),
                TerminalTimestampVisibleRow(row: 9, timestamp: laterOutput),
            ]
        )
    }
}
