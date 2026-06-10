import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Notification authorization and settings prompts
extension NotificationDockBadgeTests {
    private final class NotificationSettingsAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertFirstButtonReturn

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            return nextResponse
        }
    }

    func testNotificationAuthorizationStateMappingCoversKnownUNAuthorizationStatuses() {
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .notDetermined), .notDetermined)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .denied), .denied)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .authorized), .authorized)
        XCTAssertEqual(TerminalNotificationStore.authorizationState(from: .provisional), .provisional)
    }

    func testNotificationAuthorizationStateDeliveryCapability() {
        XCTAssertFalse(NotificationAuthorizationState.unknown.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.notDetermined.allowsDelivery)
        XCTAssertFalse(NotificationAuthorizationState.denied.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.authorized.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.provisional.allowsDelivery)
        XCTAssertTrue(NotificationAuthorizationState.ephemeral.allowsDelivery)
    }

    func testNotificationDeliveryAuthorizationUsesCachedTerminalStates() {
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .unknown, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .notDetermined, isAppActive: true))
        XCTAssertEqual(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .notDetermined, isAppActive: false), false)
        XCTAssertEqual(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .denied, isAppActive: false), false)
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .authorized, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .provisional, isAppActive: false))
        XCTAssertNil(TerminalNotificationStore.cachedDeliveryAuthorizationDecision(for: .ephemeral, isAppActive: false))
    }

    func testNotificationAuthorizationDefersFirstPromptWhileAppIsInactive() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .notDetermined,
                isAppActive: true
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldDeferAutomaticAuthorizationRequest(
                status: .authorized,
                isAppActive: false
            )
        )
    }

    func testNotificationAuthorizationRequestGatingAllowsSettingsRetry() {
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: false,
                hasRequestedAutomaticAuthorization: true
            )
        )
        XCTAssertTrue(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: false
            )
        )
        XCTAssertFalse(
            TerminalNotificationStore.shouldRequestAuthorization(
                isAutomaticRequest: true,
                hasRequestedAutomaticAuthorization: true
            )
        )
    }

    func testNotificationSettingsPromptUsesSheetAndNeverRunsModal() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        var openedURL: URL?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { window },
            alertFactory: { alertSpy },
            scheduler: { _, block in block() },
            urlOpener: { openedURL = $0 }
        )
        addTeardownBlock {
            store.resetNotificationSettingsPromptHooksForTesting()
        }

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        guard let encodedBundleIdentifier = Bundle.main.bundleIdentifier?
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            XCTFail("Expected test bundle identifier to be URL-encodable")
            return
        }
        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(encodedBundleIdentifier)"
        )
    }

    func testNotificationSettingsPromptRetriesUntilWindowExists() {
        let store = TerminalNotificationStore.shared
        let alertSpy = NotificationSettingsAlertSpy()
        alertSpy.nextResponse = .alertSecondButtonReturn

        var queuedRetryBlocks: [() -> Void] = []
        var promptWindow: NSWindow?
        store.configureNotificationSettingsPromptHooksForTesting(
            windowProvider: { promptWindow },
            alertFactory: { alertSpy },
            scheduler: { _, block in queuedRetryBlocks.append(block) },
            urlOpener: { _ in
                XCTFail("Should not open settings for Not Now response")
            }
        )
        addTeardownBlock {
            store.resetNotificationSettingsPromptHooksForTesting()
        }

        store.promptToEnableNotificationsForTesting()
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 0)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
        XCTAssertEqual(queuedRetryBlocks.count, 1)

        promptWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        queuedRetryBlocks.removeFirst()()

        XCTAssertEqual(alertSpy.beginSheetModalCallCount, 1)
        XCTAssertEqual(alertSpy.runModalCallCount, 0)
    }

}
