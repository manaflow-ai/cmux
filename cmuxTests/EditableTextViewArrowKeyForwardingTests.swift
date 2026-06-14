import AppKit
import Testing

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
@Suite("EditableTextViewArrowKeyForwarding")
struct EditableTextViewArrowKeyForwardingTests {
    @Test(arguments: [123, 124, 125, 126] as [UInt16])
    func routesPlainArrowWhenEditableTextViewFirstResponder(keyCode: UInt16) {
        #expect(
            shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: keyCode,
                firstResponderIsEditableTextView: true,
                flags: []
            ),
            "Expected editable text view to own plain arrow keyCode \(keyCode)"
        )
    }

    @Test
    func routesSelectionWordAndLineArrows() {
        let flagSets: [NSEvent.ModifierFlags] = [
            [.shift], [.option], [.option, .shift], [.command], [.command, .shift],
        ]
        for flags in flagSets {
            for keyCode in [123, 124, 125, 126] as [UInt16] {
                #expect(
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

    @Test(arguments: [123, 124, 125, 126] as [UInt16])
    func doesNotForwardWhenResponderIsNotEditableTextView(keyCode: UInt16) {
        #expect(
            !shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: keyCode,
                firstResponderIsEditableTextView: false,
                flags: []
            )
        )
    }

    @Test
    func doesNotForwardDuringMarkedTextComposition() {
        #expect(
            !shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: 125,
                firstResponderIsEditableTextView: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
    }

    @Test
    func doesNotForwardNonArrowKeys() {
        #expect(
            !shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: 0,
                firstResponderIsEditableTextView: true,
                flags: []
            )
        )
    }

    @Test(arguments: [123, 124, 125, 126] as [UInt16])
    func doesNotStealCommandOptionArrowFromPaneFocusShortcut(keyCode: UInt16) {
        // Cmd+Option+Arrow is reserved for cmux pane-focus shortcuts and must
        // not be claimed by the text view.
        #expect(
            !shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
                keyCode: keyCode,
                firstResponderIsEditableTextView: true,
                flags: [.command, .option]
            )
        )
    }
}
