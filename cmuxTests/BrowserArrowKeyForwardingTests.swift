import XCTest
import AppKit
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserArrowKeyForwardingTests: XCTestCase {
    func testRoutesAllPlainArrowKeysWhenBrowserFirstResponder() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: []
                ),
                "Expected browser responder to own plain arrow keyCode \(keyCode)"
            )
        }
    }

    func testRoutesCommandUpAndDownWhenBrowserFirstResponder() {
        for keyCode in [125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command]
                ),
                "Expected browser responder to own Cmd+vertical arrow keyCode \(keyCode)"
            )
        }
    }

    func testRoutesSelectionAndWordNavigationArrowCombos() {
        for flags in [
            NSEvent.ModifierFlags.shift,
            .option,
            [.option, .shift],
            [.command, .shift],
        ] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: 125,
                    firstResponderIsBrowser: true,
                    flags: flags
                ),
                "Expected browser editor to own Shift/Option arrow flags \(flags.rawValue)"
            )
        }
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command, .shift]
                ),
                "Expected browser editor to own Cmd+Shift arrow keyCode \(keyCode)"
            )
        }
    }

    func testDoesNotForceForwardArrowsOutsidePlainBrowserResponderPath() {
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: false, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, firstResponderHasMarkedText: true, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: true, flags: [.command]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, flags: [.command]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 126, firstResponderIsBrowser: true, flags: [.command, .option]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 125, firstResponderIsBrowser: true, flags: [.command, .option]))
    }

    @MainActor
    func testNativeModifierOwnerKeepsShiftHeldUntilBothPhysicalKeysRelease() {
        let owner = BrowserNativeInputDeliveryOwner()
        owner.setModifier(.shift, for: 56)
        owner.setModifier(.shift, for: 60)
        owner.removeModifier(for: 56)

        XCTAssertTrue(owner.activeModifierFlags.contains(.shift))

        owner.removeModifier(for: 60)
        XCTAssertFalse(owner.activeModifierFlags.contains(.shift))
    }

    func testNativeBrowserArrowMappingUsesMacVirtualKeys() {
        let expected: [(String, UInt16, String)] = [
            ("ArrowLeft", 123, "\u{F702}"),
            ("ArrowRight", 124, "\u{F703}"),
            ("ArrowDown", 125, "\u{F701}"),
            ("ArrowUp", 126, "\u{F700}"),
        ]

        for (rawKey, keyCode, characters) in expected {
            guard let event = BrowserKeyboardEvent(rawKey: rawKey),
                  let specification = SyntheticKeyEventFactory.specification(forBrowserEvent: event)
            else {
                XCTFail("Expected a native specification for \(rawKey)")
                continue
            }
            XCTAssertEqual(specification.keyCode, keyCode, "Unexpected native key code for \(rawKey)")
            XCTAssertEqual(specification.characters, characters)
            XCTAssertEqual(specification.charactersIgnoringModifiers, characters)
        }
    }
}
