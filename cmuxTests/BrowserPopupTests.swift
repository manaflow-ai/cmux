import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Popup retargeting and content rect
final class BrowserSimpleUserGesturePopupRetargetingTests: XCTestCase {
    func testKeyboardKeyDownSameSiteGETWithoutPopupFeaturesPrefersCurrentTabRetarget() {
        XCTAssertTrue(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://search.bilibili.com/all?keyword=test"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                currentEventType: .keyDown,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testKeyboardSameSiteGETWithoutPopupFeaturesPrefersCurrentTabRetarget() {
        XCTAssertTrue(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://search.bilibili.com/all?keyword=test"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testLeftClickSameSiteGETWithoutPopupFeaturesPrefersCurrentTabRetarget() {
        XCTAssertTrue(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://search.bilibili.com/all?keyword=test"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                currentEventType: .leftMouseUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testCrossSiteKeyboardPopupStaysPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
                openerURL: URL(string: "https://app.example.com/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testExplicitCommandNewTabGestureDoesNotRetargetIntoCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://search.bilibili.com/all?keyword=test"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                modifierFlags: [.command],
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testMixedSchemePopupStaysPopupEvenWhenRegistrableDomainMatches() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://login.example.com/oauth"),
                openerURL: URL(string: "http://example.com/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testGitHubPagesTenantsStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://foo.github.io/search"),
                openerURL: URL(string: "https://bar.github.io/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testAppspotTenantsStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://a.appspot.com/search"),
                openerURL: URL(string: "https://b.appspot.com/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testCloudFrontTenantsStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://foo.cloudfront.net/search"),
                openerURL: URL(string: "https://bar.cloudfront.net/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testS3TenantsStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://a.s3.amazonaws.com/search"),
                openerURL: URL(string: "https://b.s3.amazonaws.com/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testSameHostKeyboardPopupStaysPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://www.example.com/chooser"),
                openerURL: URL(string: "https://www.example.com/settings"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testCrossPortSameHostPopupStaysPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://localhost:3000/search"),
                openerURL: URL(string: "https://localhost:5000/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testDistinctBareCountryCodeSecondLevelHostsStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://foo.co.uk/search"),
                openerURL: URL(string: "https://bar.co.uk/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testCrossRegistrableDomainsUnderCommonMultiPartSuffixStayPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://foo.example.co.uk/search"),
                openerURL: URL(string: "https://bar.attacker.co.uk/login"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }

    func testPopupFeaturesKeepKeyboardRequestOnPopupPath() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "GET",
                requestURL: URL(string: "https://www.bilibili.com/search"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: true
            )
        )
    }

    func testPOSTKeyboardRequestStaysPopup() {
        XCTAssertFalse(
            browserNavigationShouldOpenSimpleUserGesturePopupInCurrentTab(
                navigationType: .other,
                requestMethod: "POST",
                requestURL: URL(string: "https://www.bilibili.com/search"),
                openerURL: URL(string: "https://www.bilibili.com/video/BV1"),
                currentEventType: .keyUp,
                popupFeaturesWereSpecified: false
            )
        )
    }
}


final class BrowserPopupContentRectTests: XCTestCase {
    func testExplicitTopOriginCoordinatesConvertToAppKitBottomOrigin() {
        let rect = browserPopupContentRect(
            requestedWidth: 400,
            requestedHeight: 300,
            requestedX: 150,
            requestedTopY: 120,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 150, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 430, accuracy: 0.01)
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 300, accuracy: 0.01)
    }

    func testExplicitCoordinatesClampToVisibleFrame() {
        let rect = browserPopupContentRect(
            requestedWidth: 1400,
            requestedHeight: 1200,
            requestedX: 900,
            requestedTopY: -25,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 50, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.height, 800, accuracy: 0.01)
    }

    func testMissingCoordinatesCentersPopup() {
        let rect = browserPopupContentRect(
            requestedWidth: 300,
            requestedHeight: 200,
            requestedX: nil,
            requestedTopY: nil,
            visibleFrame: NSRect(x: 100, y: 50, width: 1000, height: 800)
        )

        XCTAssertEqual(rect.origin.x, 450, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 350, accuracy: 0.01)
        XCTAssertEqual(rect.width, 300, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
    }
}


