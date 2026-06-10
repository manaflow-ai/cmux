import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class BrowserPanelReactGrabBridgeTests: XCTestCase {
    @MainActor
    func testExplicitWebViewFocusDoesNotSuppressOmnibarAutofocusWhenFocusFails() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertFalse(panel.shouldSuppressOmnibarAutofocus())
        XCTAssertFalse(panel.requestExplicitWebViewFocus())
        XCTAssertFalse(panel.shouldSuppressOmnibarAutofocus())
    }

    func testOmnibarVisibilityIsPanelScopedAndFocusRequestShowsIt() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isOmnibarVisible)
        _ = panel.requestAddressBarFocus()
        XCTAssertNotNil(panel.pendingAddressBarFocusRequestId)

        XCTAssertTrue(panel.setOmnibarVisible(false))
        XCTAssertFalse(panel.isOmnibarVisible)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
        XCTAssertEqual(panel.preferredFocusIntent, .webView)
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())

        let requestId = panel.requestAddressBarFocus()
        XCTAssertTrue(panel.isOmnibarVisible)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertEqual(panel.preferredFocusIntent, .addressBar)
    }

    func testCopySuccessPostsPastebackNotificationAndClearsPendingTarget() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testInactiveStateKeepsPendingTargetUntilCopySuccess() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification after deactivate")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: false))

        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        XCTAssertFalse(panel.isReactGrabActive)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testResetStateCanPreservePendingTargetUntilCopySuccess() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let browserId = panel.id
        let expectation = expectation(description: "react grab pasteback notification after reset")

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID, workspaceId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID, browserId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID, terminalId)
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.resetReactGrabState(
            preserveRoundTrip: true,
            reason: "test.navigation"
        )

        XCTAssertFalse(panel.isReactGrabActive)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: token))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testMismatchedCopyTokenDropsPastebackAndClearsPendingTarget() {
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: UUID())
        let invertedExpectation = expectation(description: "react grab pasteback notification")
        invertedExpectation.isInverted = true

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { _ in
            invertedExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        XCTAssertEqual(panel.pendingReactGrabReturnTargetPanelId, terminalId)
        XCTAssertNotNil(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: "<button>Save</button>", token: nil))

        wait(for: [invertedExpectation], timeout: 0.1)
        XCTAssertNil(panel.pendingReactGrabReturnTargetPanelId)
        XCTAssertNil(panel.pendingReactGrabRoundTripToken)
    }

    func testCopySuccessStripsDangerousInvisibleScalarsBeforePastebackNotification() throws {
        let workspaceId = UUID()
        let terminalId = UUID()
        let panel = BrowserPanel(workspaceId: workspaceId)
        let expectation = expectation(description: "react grab pasteback notification")
        let rawContent = "<button>Sa\u{202E}v\u{200B}e</button>\u{2069}\n"

        let observer = NotificationCenter.default.addObserver(
            forName: .reactGrabDidCopySelection,
            object: nil,
            queue: .main
        ) { notification in
            XCTAssertEqual(notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String, "<button>Save</button>\n")
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        panel.armReactGrabRoundTrip(returnTo: terminalId)
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        panel.handleReactGrabBridgeMessage(.copySuccess(content: rawContent, token: token))

        wait(for: [expectation], timeout: 1.0)
    }

    func testEnsureReactGrabActiveRefreshesBridgeSessionTokenWhenAlreadyActive() async throws {
        let panel = BrowserPanel(workspaceId: UUID())

        _ = try await panel.evaluateJavaScript(
            """
            window['\(panel.reactGrabBridgeSessionUpdaterName)'] = function(token) {
                window.__cmuxTestRoundTripToken = token;
                return true;
            };
            true;
            """
        )

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        panel.armReactGrabRoundTrip(returnTo: UUID())
        let token = try XCTUnwrap(panel.pendingReactGrabRoundTripToken)

        await panel.ensureReactGrabActive()

        let refreshedToken = try await panel.evaluateJavaScript("window.__cmuxTestRoundTripToken") as? String
        XCTAssertEqual(refreshedToken, token)
    }
}


