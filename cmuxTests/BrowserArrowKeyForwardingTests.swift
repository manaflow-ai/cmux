import XCTest
import AppKit

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

    func testDoesNotForceForwardArrowsOutsidePlainBrowserResponderPath() {
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: false, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, firstResponderHasMarkedText: true, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: true, flags: [.command]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, flags: [.command]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 126, firstResponderIsBrowser: true, flags: [.command, .option]))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 125, firstResponderIsBrowser: true, flags: [.command, .option]))
    }

    // MARK: - Selection / word-jump combos
    // Shift+arrow, Option+arrow, Shift+Option+arrow, and Cmd+Shift+Up/Down must
    // be routed via firstResponder.keyDown so AppKit's interpretKeyEvents path
    // fires moveLeftAndModifySelection: / moveWordRight: / etc. into WebKit.

    func testRoutesShiftArrowForSelectionExtension() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.shift]
                ),
                "Shift+arrow keyCode \(keyCode) must route to browser for selection extension"
            )
        }
    }

    func testRoutesOptionArrowForWordOrParagraphJump() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.option]
                ),
                "Option+arrow keyCode \(keyCode) must route to browser for word/paragraph jump"
            )
        }
    }

    func testRoutesShiftOptionArrowForWordParagraphSelection() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.shift, .option]
                ),
                "Shift+Option+arrow keyCode \(keyCode) must route to browser for word/paragraph selection"
            )
        }
    }

    func testRoutesCommandShiftUpAndDownForDocumentBoundarySelection() {
        for keyCode in [125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command, .shift]
                ),
                "Cmd+Shift+vertical arrow keyCode \(keyCode) must route to browser for document-boundary selection"
            )
        }
    }

    // MARK: - Regression guards for cmux-owned chords / deliberate scope

    func testDoesNotRouteCommandOptionArrowForAnyDirection() {
        // cmux uses Cmd+Option+Arrow for focusLeft/focusRight/focusUp/focusDown
        // pane navigation. Selection-arrow extensions must not steal these.
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertFalse(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command, .option]
                ),
                "Cmd+Option+arrow keyCode \(keyCode) is cmux pane-focus and must NOT route to browser"
            )
            XCTAssertFalse(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command, .option, .shift]
                ),
                "Cmd+Option+Shift+arrow keyCode \(keyCode) must not route; still owned by cmux"
            )
        }
    }

    func testDoesNotRouteCommandShiftHorizontalArrowsByCurrentScope() {
        // Cmd+Shift+Left/Right (extend selection to line start/end) is deliberately
        // out of scope until a user reports a bug — symmetric with the existing
        // decision to not route plain Cmd+Left/Right. Guard the scope.
        for keyCode in [123, 124] as [UInt16] {
            XCTAssertFalse(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: [.command, .shift]
                ),
                "Cmd+Shift+horizontal arrow keyCode \(keyCode) is deliberately out of current routing scope"
            )
        }
    }
}
