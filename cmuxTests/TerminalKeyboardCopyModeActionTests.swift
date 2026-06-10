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


final class TerminalKeyboardCopyModeActionTests: XCTestCase {
    func testCopyModeBypassAllowsOnlyCommandShortcuts() {
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .shift]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option, .shift]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.control]))
    }

    func testVimMotionsWithoutSelectionMoveCursorInsteadOfViewport() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.down)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.up)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 4,
                charactersIgnoringModifiers: "h",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.left)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.right)
        )
    }

    func testVimKeysResolveUnderNonASCIIKeyboardLayout() {
        // Korean 2-set (두벌식) reports non-ASCII characters for physical vim keys.
        // Copy-mode vim keys must still resolve to a
        // cursor motion via the ASCII-capable layout fallback, without forcing the
        // user to switch input sources. The character provider is injected so this
        // test is deterministic and independent of the CI runner's input source.
        let asciiProvider: (UInt16, NSEvent.ModifierFlags) -> String? = { keyCode, _ in
            switch keyCode {
            case 4: return "h"
            case 38: return "j"
            case 40: return "k"
            case 37: return "l"
            default: return nil
            }
        }
        let cases: [(keyCode: UInt16, characters: String, move: TerminalKeyboardCopyModeSelectionMove)] = [
            (4, "ㅗ", .left),
            (38, "ㅓ", .down),
            (40, "ㅏ", .up),
            (37, "ㅣ", .right),
        ]

        for testCase in cases {
            XCTAssertEqual(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifierFlags: [],
                    hasSelection: false,
                    asciiCharacterProvider: asciiProvider
                ),
                .adjustSelection(testCase.move)
            )
        }
    }

    func testCapsLockDoesNotBlockLetterMappings() {
        let cases: [(keyCode: UInt16, characters: String, move: TerminalKeyboardCopyModeSelectionMove)] = [
            (4, "h", .left),
            (38, "j", .down),
            (40, "k", .up),
            (37, "l", .right),
        ]

        for testCase in cases {
            XCTAssertEqual(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifierFlags: [.capsLock],
                    hasSelection: false
                ),
                .adjustSelection(testCase.move)
            )
        }
    }

    func testJKWithSelectionAdjustSelection() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.up)
        )
    }

    func testControlPagingSupportsPrintableAndControlCharacters() {
        // Ctrl+U = half-page up (vim standard).
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{15}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollHalfPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{04}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{02}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{06}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{19}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollLines(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{05}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollLines(1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{05}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
    }

    func testVGYMapping() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: true
            ),
            .clearSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 16,
                charactersIgnoringModifiers: "y",
                modifierFlags: [],
                hasSelection: true
            ),
            .copyAndExit
        )
    }

    func testGAndShiftGMapping() {
        // Bare "g" is a prefix key (gg), not an immediate action.
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .scrollToBottom
        )
    }

    func testLineBoundaryPromptAndSearchMappings() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 20,
                charactersIgnoringModifiers: "^",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .adjustSelection(.endOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.endOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(1)
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [],
                hasSelection: true
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 44,
                charactersIgnoringModifiers: "/",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSearch
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [],
                hasSelection: false
            ),
            .searchNext
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .searchPrevious
        )
    }

    func testShiftVMatchesVisualToggleBehavior() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .clearSelection
        )
    }

    func testEscapeAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 53,
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }

    func testQAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 12, // kVK_ANSI_Q
                charactersIgnoringModifiers: "q",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }
}


