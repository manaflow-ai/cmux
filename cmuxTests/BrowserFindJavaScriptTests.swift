import XCTest
import AppKit
import WebKit
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Find-in-page script generation and escaping moved into the CmuxBrowser package
// (BrowserFindScript). Its behavior is covered by CmuxBrowserTests/Find/BrowserFindServiceTests.

final class BrowserPopupDecisionTests: XCTestCase {
    func testLinkActivatedPlainLeftClickDoesNotCreatePopup() {
        XCTAssertFalse(
            BrowserUserGestureNavigation(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            ).createsPopup()
        )
    }

    func testOtherNavigationWithPopupFeaturesCreatesPopup() {
        XCTAssertTrue(
            BrowserUserGestureNavigation(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            ).createsPopup(popupFeaturesWereSpecified: true)
        )
    }

    func testOtherNavigationWithoutPopupFeaturesDoesNotCreatePopup() {
        XCTAssertFalse(
            BrowserUserGestureNavigation(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            ).createsPopup()
        )
    }

    func testOtherNavigationMiddleClickDoesNotCreatePopup() {
        XCTAssertFalse(
            BrowserUserGestureNavigation(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            ).createsPopup()
        )
    }

    func testLinkActivatedCmdClickDoesNotCreatePopup() {
        XCTAssertFalse(
            BrowserUserGestureNavigation(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            ).createsPopup()
        )
    }

    func testPopupFeaturesAreAbsentWhenAllWindowFeaturesAreNil() {
        XCTAssertFalse(
            BrowserPopupWindowFeatures(
                x: nil,
                y: nil,
                width: nil,
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            ).wereSpecified
        )
    }

    func testPopupFeaturesArePresentWhenWidthIsSpecified() {
        XCTAssertTrue(
            BrowserPopupWindowFeatures(
                x: nil,
                y: nil,
                width: NSNumber(value: 640),
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            ).wereSpecified
        )
    }
}
