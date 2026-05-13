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

    func testSwiftUIHostGeometryCallbackSchedulesExternalSynchronization() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .scheduleExternal(let window):
            XCTAssertEqual(window, 3873)
        case .skip:
            XCTFail("Window-attached host callbacks should schedule deferred portal synchronization")
        }
    }

    func testSwiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .scheduleExternal:
            XCTFail("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
    func testTerminalTimestampStorePrunesRowsOutsideRetentionWindow() {
        let store = TerminalTimestampStore(maxRetainedRows: 3)
        let timestamp = Date(timeIntervalSince1970: 100)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 0, offset: 0, len: 0),
            at: timestamp,
            markVisibleRows: false
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 5),
            at: timestamp,
            markVisibleRows: false
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 5)),
            [
                TerminalTimestampVisibleRow(row: 2, timestamp: timestamp),
                TerminalTimestampVisibleRow(row: 3, timestamp: timestamp),
                TerminalTimestampVisibleRow(row: 4, timestamp: timestamp),
            ]
        )
    }

    @MainActor
    func testTerminalTimestampStoreClearsRebasedRowsAfterScrollbackShrink() {
        let store = TerminalTimestampStore()
        let oldTimestamp = Date(timeIntervalSince1970: 100)
        let reboundTimestamp = Date(timeIntervalSince1970: 200)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 8, offset: 0, len: 8),
            at: oldTimestamp,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 5),
            at: reboundTimestamp,
            markVisibleRows: true
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 5)),
            [
                TerminalTimestampVisibleRow(row: 0, timestamp: reboundTimestamp),
                TerminalTimestampVisibleRow(row: 1, timestamp: reboundTimestamp),
                TerminalTimestampVisibleRow(row: 2, timestamp: reboundTimestamp),
                TerminalTimestampVisibleRow(row: 3, timestamp: reboundTimestamp),
                TerminalTimestampVisibleRow(row: 4, timestamp: reboundTimestamp),
            ]
        )
    }

    @MainActor
    func testTerminalTimestampStoreKeepsVisibleRowsMarkedOutsideRetentionWindow() {
        let store = TerminalTimestampStore(maxRetainedRows: 3)
        let tailTimestamp = Date(timeIntervalSince1970: 100)
        let visibleTimestamp = Date(timeIntervalSince1970: 200)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 2, len: 3),
            at: tailTimestamp,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2),
            at: visibleTimestamp,
            markVisibleRows: true
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2)),
            [
                TerminalTimestampVisibleRow(row: 0, timestamp: visibleTimestamp),
                TerminalTimestampVisibleRow(row: 1, timestamp: visibleTimestamp),
            ]
        )
    }

    @MainActor
    func testTerminalTimestampStorePreservesMarkedVisibleRowsAcrossScrollUpdates() {
        let store = TerminalTimestampStore(maxRetainedRows: 3)
        let tailTimestamp = Date(timeIntervalSince1970: 100)
        let visibleTimestamp = Date(timeIntervalSince1970: 200)
        let scrollTimestamp = Date(timeIntervalSince1970: 300)

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 2, len: 3),
            at: tailTimestamp,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2),
            at: visibleTimestamp,
            markVisibleRows: true
        )
        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2),
            at: scrollTimestamp,
            markVisibleRows: false
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2)),
            [
                TerminalTimestampVisibleRow(row: 0, timestamp: visibleTimestamp),
                TerminalTimestampVisibleRow(row: 1, timestamp: visibleTimestamp),
            ]
        )

        store.record(
            scrollbar: TerminalTimestampScrollbarState(total: 5, offset: 2, len: 3),
            at: scrollTimestamp,
            markVisibleRows: false
        )

        XCTAssertEqual(
            store.visibleRows(for: TerminalTimestampScrollbarState(total: 5, offset: 0, len: 2)),
            []
        )
    }
}
