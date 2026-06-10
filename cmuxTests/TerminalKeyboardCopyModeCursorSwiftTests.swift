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


@Suite("Terminal keyboard copy mode cursor")
struct TerminalKeyboardCopyModeCursorSwiftTests {
    @Test func clampKeepsStoredCursorInsideResizedGrid() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 25, column: 90)
        cursor.clamp(rows: 10, columns: 20)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 19))

        cursor = TerminalKeyboardCopyModeCursor(row: -4, column: -2)
        cursor.clamp(rows: 0, columns: 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 0))
    }

    @Test func homeAndEndResetBothAxes() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        #expect(cursor.move(.home, count: 1, rows: 10, columns: 8) == 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 0))

        cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        #expect(cursor.move(.end, count: 1, rows: 10, columns: 8) == 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 7))
    }

    @Test func viewportScrollShiftsCursorToStayOnSameText() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        cursor.shiftForViewportScroll(lineDelta: 2, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 3, column: 3))

        cursor.shiftForViewportScroll(lineDelta: -4, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 7, column: 3))
    }

    @Test func viewportScrollShiftClampsAtEdges() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 1, column: 99)
        cursor.shiftForViewportScroll(lineDelta: 5, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 7))

        cursor = TerminalKeyboardCopyModeCursor(row: 8, column: -2)
        cursor.shiftForViewportScroll(lineDelta: -5, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 0))
    }

    @Test func terminalSelectionAdjustmentKeepsEndpointAtViewportEdge() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 9, column: 3)
        cursor.moveAfterTerminalSelectionAdjustment(.down, count: 1, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 3))

        cursor = TerminalKeyboardCopyModeCursor(row: 0, column: 3)
        cursor.moveAfterTerminalSelectionAdjustment(.up, count: 1, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 3))
    }

    @Test func visualSelectionAnchorFollowsMovedCursor() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 8, column: 7)

        let moveAction = terminalKeyboardCopyModeAction(
            keyCode: 38,
            charactersIgnoringModifiers: "j",
            modifierFlags: [],
            hasSelection: false
        )
        #expect(moveAction == .adjustSelection(.down))
        if case let .adjustSelection(move)? = moveAction {
            #expect(cursor.move(move, count: 1, rows: 20, columns: 40) == 0)
        }

        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: false
            ) == .startSelection
        )
        #expect(cursor.clamped(rows: 20, columns: 40) == TerminalKeyboardCopyModeCursor(row: 9, column: 7))
    }
}


