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


final class GhosttyModifierFlagsChangedActionTests: XCTestCase {
    func testLeftShiftPressReturnsPress() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ),
            GHOSTTY_ACTION_PRESS
        )
    }

    func testLeftShiftReleaseReturnsRelease() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: 0
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testLeftShiftWithoutLeftSideDeviceMaskReturnsReleaseWhenRightShiftHeld() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x38,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testRightShiftRequiresRightSideDeviceMaskForPress() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
            ),
            GHOSTTY_ACTION_PRESS
        )
    }

    func testRightShiftWithoutRightSideDeviceMaskReturnsRelease() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testRightShiftWithoutRightSideDeviceMaskReturnsReleaseWhenLeftShiftHeld() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3C,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testRightControlRequiresRightSideDeviceMaskForPress() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue | UInt(NX_DEVICERCTLKEYMASK)
            ),
            GHOSTTY_ACTION_PRESS
        )
    }

    func testRightControlWithoutRightSideDeviceMaskReturnsRelease() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3E,
                modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testRightOptionRequiresRightSideDeviceMaskForPress() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK)
            ),
            GHOSTTY_ACTION_PRESS
        )
    }

    func testRightOptionWithoutRightSideDeviceMaskReturnsRelease() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x3D,
                modifierFlagsRawValue: NSEvent.ModifierFlags.option.rawValue
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testRightCommandRequiresRightSideDeviceMaskForPress() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x36,
                modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICERCMDKEYMASK)
            ),
            GHOSTTY_ACTION_PRESS
        )
    }

    func testCapsLockUsesLogicalModifierState() {
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: NSEvent.ModifierFlags.capsLock.rawValue
            ),
            GHOSTTY_ACTION_PRESS
        )
        XCTAssertEqual(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x39,
                modifierFlagsRawValue: 0
            ),
            GHOSTTY_ACTION_RELEASE
        )
    }

    func testNonModifierKeyReturnsNil() {
        XCTAssertNil(
            cmuxGhosttyModifierActionForFlagsChanged(
                keyCode: 0x00,
                modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue
            )
        )
    }
}


