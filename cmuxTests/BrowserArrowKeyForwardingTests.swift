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

    func testRoutesPlainAndShiftArrowKeysToEditableTextViews() {
        let textView = NSTextView()
        textView.isEditable = true

        XCTAssertTrue(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 123, responder: textView, flags: []))
        XCTAssertTrue(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 124, responder: textView, flags: [.shift]))
    }

    func testDoesNotStealModifiedArrowShortcutsFromEditableTextViews() {
        let textView = NSTextView()
        textView.isEditable = true

        XCTAssertFalse(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 125, responder: textView, flags: [.command]))
        XCTAssertFalse(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 126, responder: textView, flags: [.option]))
        XCTAssertFalse(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 126, responder: nil, flags: []))

        textView.isEditable = false
        XCTAssertFalse(shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(keyCode: 123, responder: textView, flags: []))
    }
}
