@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Focus-follows-mouse first responder decisions
extension GhosttyMouseFocusTests {
    func testShouldRequestFirstResponderForMouseFocusWhenEnabledAndWindowIsActive() {
        XCTAssertTrue(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenFocusFollowsMouseDisabled() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: false,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderDuringMouseDrag() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 1,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: false
            )
        )
    }

    func testShouldNotRequestFirstResponderWhenViewCannotSafelyReceiveFocus() {
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: false,
                hiddenInHierarchy: false
            )
        )
        XCTAssertFalse(
            GhosttyNSView.shouldRequestFirstResponderForMouseFocus(
                focusFollowsMouseEnabled: true,
                pressedMouseButtons: 0,
                appIsActive: true,
                windowIsKey: true,
                alreadyFirstResponder: false,
                visibleInUI: true,
                hasUsableGeometry: true,
                hiddenInHierarchy: true
            )
        )
    }

    // MARK: - CJK Font Fallback

}
