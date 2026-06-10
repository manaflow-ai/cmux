import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalKeyboardCopyModeViewportRowTests: XCTestCase {
    func testInitialViewportRowUsesImePointBaseline() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 24,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 240,
                imeCellHeight: 24
            ),
            9
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 48,
                imeCellHeight: 24,
                topPadding: 24
            ),
            0
        )
    }

    func testInitialViewportRowClampsBoundsAndFallsBackWhenHeightMissing() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 0,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 9999,
                imeCellHeight: 24
            ),
            23
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 123,
                imeCellHeight: 0
            ),
            23
        )
    }

    func testInitialViewportColumnUsesImePointMidpoint() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 5,
                imeCellWidth: 10
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 235,
                imeCellWidth: 10,
                leftPadding: 5
            ),
            23
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 9999,
                imeCellWidth: 10
            ),
            79
        )
    }

    func testCursorMovementReturnsScrollDeltaOnlyAtVerticalEdges() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        XCTAssertEqual(cursor.move(.down, count: 2, rows: 10, columns: 8), 0)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 7, column: 3))

        XCTAssertEqual(cursor.move(.down, count: 4, rows: 10, columns: 8), 2)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 9, column: 3))

        XCTAssertEqual(cursor.move(.up, count: 12, rows: 10, columns: 8), -3)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 0, column: 3))
    }

    func testCursorSelectionXRangeUsesCellInteriorWhenAvailable() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 20,
                rectMaxX: 30,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 20.5, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 29.5, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeKeepsNonzeroDragAtRightEdge() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 99.5,
                rectMaxX: 120,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 98, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 99, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeKeepsNonzeroDragForCollapsedCellWidth() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 50,
                rectMaxX: 50.4,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 50.2, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 51.2, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeReturnsNilWhenViewCannotExpressHorizontalDrag() {
        XCTAssertNil(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 0,
                rectMaxX: 10,
                boundsWidth: 1
            )
        )
    }
}


