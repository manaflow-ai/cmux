import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5227.
///
/// In a cmux window every keyDown is funneled through the swizzled
/// `NSWindow.performKeyEquivalent`, where the original AppKit implementation
/// swallows plain arrow keys (keyCodes 123-126) before they reach the focused
/// view's `keyDown`. The window swizzle re-routes arrows to
/// `firstResponder.keyDown(with:)` only for an enumerated set of responder
/// types. The file-editor text view (`SavingTextView`, a standalone editable
/// `NSTextView`) was missing from that set, so arrow keys never moved the
/// cursor. These tests pin the generalized routing decision that fixes the
/// whole class: any standalone editable `NSTextView` owns arrow navigation.
final class EditableTextViewArrowKeyForwardingTests: XCTestCase {
    func testRoutesAllPlainArrowKeysWhenEditableTextViewFirstResponder() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsEditableTextView: true,
                    flags: []
                ),
                "Expected editable text view to own plain arrow keyCode \(keyCode)"
            )
        }
    }

    func testRoutesSelectionWordAndLineArrows() {
        let flagSets: [NSEvent.ModifierFlags] = [
            [.shift], [.option], [.option, .shift], [.command], [.command, .shift],
        ]
        for flags in flagSets {
            for keyCode in [123, 124, 125, 126] as [UInt16] {
                XCTAssertTrue(
                    shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                        keyCode: keyCode,
                        firstResponderIsEditableTextView: true,
                        flags: flags
                    ),
                    "Expected editable text view to own modified arrow keyCode \(keyCode) flags \(flags.rawValue)"
                )
            }
        }
    }

    func testDoesNotForwardWhenResponderIsNotEditableTextView() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertFalse(
                shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsEditableTextView: false,
                    flags: []
                )
            )
        }
    }

    func testDoesNotForwardDuringMarkedTextComposition() {
        XCTAssertFalse(
            shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: 125,
                firstResponderIsEditableTextView: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    func testDoesNotForwardNonArrowKeys() {
        XCTAssertFalse(
            shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: 0,
                firstResponderIsEditableTextView: true,
                flags: []
            )
        )
    }

    func testDoesNotStealCommandOptionArrowFromPaneFocusShortcut() {
        // Cmd+Option+Arrow is reserved for cmux pane-focus shortcuts and must
        // not be claimed by the text view.
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertFalse(
                shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsEditableTextView: true,
                    flags: [.command, .option]
                )
            )
        }
    }
}
