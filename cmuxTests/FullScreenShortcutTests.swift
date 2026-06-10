import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Full screen shortcut matching
final class FullScreenShortcutTests: XCTestCase {
    func testMatchesCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testMatchesCommandControlFFromKeyCodeWhenCharsAreUnavailable() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testDoesNotFallbackToANSIWhenLayoutTranslationReturnsNonFCharacter() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in "u" }
            )
        )
    }

    func testMatchesCommandControlFWhenCommandAwareLayoutTranslationProvidesF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "",
                keyCode: 3,
                layoutCharacterProvider: { _, modifierFlags in
                    modifierFlags.contains(.command) ? "f" : "u"
                }
            )
        )
    }

    func testMatchesCommandControlFWhenCharsAreControlSequence() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "\u{06}",
                keyCode: 3,
                layoutCharacterProvider: { _, _ in nil }
            )
        )
    }

    func testRejectsPhysicalFWhenCharacterRepresentsDifferentLayoutKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "u",
                keyCode: 3
            )
        )
    }

    func testIgnoresCapsLockForCommandControlF() {
        XCTAssertTrue(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .capsLock],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenControlIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsAdditionalModifiers() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .shift],
                chars: "f",
                keyCode: 3
            )
        )
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control, .option],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsWhenCommandIsMissing() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.control],
                chars: "f",
                keyCode: 3
            )
        )
    }

    func testRejectsNonFKey() {
        XCTAssertFalse(
            shouldToggleMainWindowFullScreenForCommandControlFShortcut(
                flags: [.command, .control],
                chars: "r",
                keyCode: 15
            )
        )
    }
}


