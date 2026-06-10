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


// MARK: - Navigation new-tab and nil-target fallback decisions
final class BrowserNavigationNewTabDecisionTests: XCTestCase {
    func testLinkActivatedCmdClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testLinkActivatedPlainLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testOtherNavigationMiddleClickOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    func testOtherNavigationLeftClickStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    func testLinkActivatedButtonFourWithoutMiddleIntentStaysInCurrentTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: false
            )
        )
    }

    func testLinkActivatedButtonFourWithRecentMiddleIntentOpensInNewTab() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 4,
                hasRecentMiddleClickIntent: true
            )
        )
    }

    func testLinkActivatedUsesCurrentEventFallbackForMiddleClick() {
        XCTAssertTrue(
            browserNavigationShouldOpenInNewTab(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testCurrentEventFallbackDoesNotAffectNonLinkNavigation() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [],
                buttonNumber: 0,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }

    func testNonLinkNavigationNeverForcesNewTab() {
        XCTAssertFalse(
            browserNavigationShouldOpenInNewTab(
                navigationType: .reload,
                modifierFlags: [.command],
                buttonNumber: 2
            )
        )
    }
}


final class BrowserNilTargetFallbackDecisionTests: XCTestCase {
    func testOtherNavigationDoesNotFallbackToNewTab() {
        XCTAssertFalse(
            browserNavigationShouldFallbackNilTargetToNewTab(
                navigationType: .other
            )
        )
    }

    func testLinkActivatedNavigationFallsBackToNewTab() {
        XCTAssertTrue(
            browserNavigationShouldFallbackNilTargetToNewTab(
                navigationType: .linkActivated
            )
        )
    }
}


