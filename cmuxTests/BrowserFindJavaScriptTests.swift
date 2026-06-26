import XCTest
import AppKit
import WebKit

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
            browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationWithPopupFeaturesCreatesPopup() {
        XCTAssertTrue(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0,
                popupFeaturesWereSpecified: true,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            )
        )
    }

    func testOtherNavigationWithoutPopupFeaturesDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationMiddleClickDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testLinkActivatedCmdClickDoesNotCreatePopup() {
        XCTAssertFalse(
            browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }

    func testPopupFeaturesAreAbsentWhenAllWindowFeaturesAreNil() {
        XCTAssertFalse(
            browserNavigationPopupFeaturesWereSpecified(
                x: nil,
                y: nil,
                width: nil,
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            )
        )
    }

    func testPopupFeaturesArePresentWhenWidthIsSpecified() {
        XCTAssertTrue(
            browserNavigationPopupFeaturesWereSpecified(
                x: nil,
                y: nil,
                width: NSNumber(value: 640),
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            )
        )
    }

    // MARK: - Blank-targeted scripted popups (#6649)

    func testBlankScriptedWindowOpenCreatesPopupForAboutBlank() throws {
        // window.open("about:blank") with no features is the deferred-navigation
        // pattern (VS Code Web auth). It must return a live popup web view, even
        // though no window features were specified.
        XCTAssertTrue(
            browserNavigationShouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: try XCTUnwrap(URL(string: "about:blank"))
            )
        )
    }

    func testBlankScriptedWindowOpenCreatesPopupForNilURL() {
        // window.open() with no argument can surface a nil request URL.
        XCTAssertTrue(
            browserNavigationShouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: nil
            )
        )
    }

    func testBlankScriptedPopupIgnoresRealDestinationURL() throws {
        // window.open("https://example.com") already carries its destination, so a
        // tab navigation works; do not force it onto the blank-popup path.
        XCTAssertFalse(
            browserNavigationShouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: try XCTUnwrap(URL(string: "https://example.com/"))
            )
        )
    }

    func testBlankScriptedPopupIgnoresLinkActivatedNavigation() throws {
        // A real link click (target=_blank) is .linkActivated, not scripted, and
        // must keep falling through to tab handling.
        XCTAssertFalse(
            browserNavigationShouldCreateBlankScriptedPopup(
                navigationType: .linkActivated,
                requestURL: try XCTUnwrap(URL(string: "about:blank"))
            )
        )
    }
}
