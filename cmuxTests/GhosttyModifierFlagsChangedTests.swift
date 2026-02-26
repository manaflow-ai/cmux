import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyModifierFlagsChangedTests: XCTestCase {
    func testLeftShiftPressMapsToPressAction() {
        let view = GhosttyNSView(frame: .zero)
        let event = makeFlagsChangedEvent(keyCode: 0x38, modifierFlags: [.shift])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertEqual(action, GHOSTTY_ACTION_PRESS)
    }

    func testLeftShiftReleaseMapsToReleaseAction() {
        let view = GhosttyNSView(frame: .zero)
        let event = makeFlagsChangedEvent(keyCode: 0x38, modifierFlags: [])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertEqual(action, GHOSTTY_ACTION_RELEASE)
    }

    func testRightShiftReleaseWhileLeftStillHeldMapsToReleaseAction() {
        let view = GhosttyNSView(frame: .zero)
        let event = makeFlagsChangedEvent(keyCode: 0x3C, modifierFlags: [.shift])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertEqual(action, GHOSTTY_ACTION_RELEASE)
    }

    func testRightShiftPressWithDeviceMaskMapsToPressAction() {
        let view = GhosttyNSView(frame: .zero)
        let rightShiftMask = NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERSHIFTKEYMASK))
        let event = makeFlagsChangedEvent(keyCode: 0x3C, modifierFlags: [.shift, rightShiftMask])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertEqual(action, GHOSTTY_ACTION_PRESS)
    }

    func testFlagsChangedIgnoredDuringMarkedTextComposition() {
        let view = GhosttyNSView(frame: .zero)
        view.setMarkedText(
            "한",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let event = makeFlagsChangedEvent(keyCode: 0x38, modifierFlags: [.shift])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertNil(action)
    }

    func testUnknownModifierKeyCodeReturnsNilAction() {
        let view = GhosttyNSView(frame: .zero)
        let event = makeFlagsChangedEvent(keyCode: 0x00, modifierFlags: [])
        let action = view.flagsChangedActionForTesting(event: event)
        XCTAssertNil(action)
    }

    private func makeFlagsChangedEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to create flagsChanged event")
        }
        return event
    }
}
