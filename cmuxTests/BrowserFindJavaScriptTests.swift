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

    func testCreateWebViewDecisionRoutesBareOtherNavigationToNewTab() {
        XCTAssertEqual(
            browserCreateWebViewDecision(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://example.com"),
                openerURL: URL(string: "https://app.example.com"),
                modifierFlags: [],
                buttonNumber: 0,
                popupFeaturesWereSpecified: false,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            ),
            .newTab
        )
    }

    func testCreateWebViewDecisionRoutesExplicitFeaturesToPopup() {
        XCTAssertEqual(
            browserCreateWebViewDecision(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://accounts.example.com/oauth"),
                openerURL: URL(string: "https://app.example.com/login"),
                modifierFlags: [],
                buttonNumber: 0,
                popupFeaturesWereSpecified: true,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            ),
            .popup
        )
    }

    func testCreateWebViewDecisionKeepsSimpleSameSiteSearchInCurrentTab() {
        XCTAssertEqual(
            browserCreateWebViewDecision(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://search.bilibili.com/all?keyword=test"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                modifierFlags: [],
                buttonNumber: 0,
                popupFeaturesWereSpecified: false,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            ),
            .currentTab
        )
    }

    func testCreateWebViewDecisionKeepsMiddleClickOnNewTabPath() {
        XCTAssertEqual(
            browserCreateWebViewDecision(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://accounts.example.com/oauth"),
                openerURL: URL(string: "https://app.example.com/login"),
                modifierFlags: [],
                buttonNumber: 2,
                popupFeaturesWereSpecified: true
            ),
            .newTab
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
}
