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


final class TerminalKeyboardCopyModeResolveTests: XCTestCase {
    private func resolve(
        _ keyCode: UInt16,
        chars: String,
        modifiers: NSEvent.ModifierFlags = [],
        hasSelection: Bool,
        state: inout TerminalKeyboardCopyModeInputState
    ) -> TerminalKeyboardCopyModeResolution {
        terminalKeyboardCopyModeResolve(
            keyCode: keyCode,
            charactersIgnoringModifiers: chars,
            modifierFlags: modifiers,
            hasSelection: hasSelection,
            state: &state
        )
    }

    func testCountPrefixAppliesToMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 3))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testZeroAppendsCountOrActsAsMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(19, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(29, chars: "0", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(40, chars: "k", hasSelection: false, state: &state), .perform(.adjustSelection(.up), count: 20))

        var zeroMotionState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(29, chars: "0", hasSelection: false, state: &zeroMotionState),
            .perform(.adjustSelection(.beginningOfLine), count: 1)
        )

        var selectionState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(29, chars: "0", hasSelection: true, state: &selectionState),
            .perform(.adjustSelection(.beginningOfLine), count: 1)
        )
    }

    func testYankLineOperatorSupportsYYAndYWithCounts() {
        var yyState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .perform(.copyLineAndExit, count: 1))

        var countedState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(21, chars: "4", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .perform(.copyLineAndExit, count: 4))

        var shiftYState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &shiftYState), .consume)
        XCTAssertEqual(
            resolve(16, chars: "y", modifiers: [.shift], hasSelection: false, state: &shiftYState),
            .perform(.copyLineAndExit, count: 3)
        )
    }

    func testPendingYankLineDoesNotSwallowNextCommand() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testSearchAndPromptMotionsUseCounts() {
        var promptState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &promptState), .consume)
        XCTAssertEqual(
            resolve(30, chars: "]", modifiers: [.shift], hasSelection: false, state: &promptState),
            .perform(.jumpToPrompt(1), count: 3)
        )

        var searchState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &searchState), .consume)
        XCTAssertEqual(resolve(45, chars: "n", hasSelection: false, state: &searchState), .perform(.searchNext, count: 2))
    }

    func testInvalidKeyClearsPendingState() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(7, chars: "x", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - gg (scroll to top via two-key sequence)

    func testGGScrollsToTop() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testGGWithSelectionAdjustsToHome() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .perform(.adjustSelection(.home), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testCountedGG() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(22, chars: "5", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 5))
    }

    func testPendingGCancelledByOtherKey() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testShiftGStillWorksImmediately() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(5, chars: "g", modifiers: [.shift], hasSelection: false, state: &state),
            .perform(.scrollToBottom, count: 1)
        )
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - Ctrl+U/D half-page scroll

    func testCtrlUHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(32, chars: "u", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(-1), count: 1)
        )
    }

    func testCtrlDHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(2, chars: "d", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(1), count: 1)
        )
    }

    func testCtrlBFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(11, chars: "b", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(-1), count: 1)
        )
    }

    func testCtrlFFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(3, chars: "f", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(1), count: 1)
        )
    }
}


