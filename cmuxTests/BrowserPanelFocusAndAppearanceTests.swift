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
import CmuxBrowser

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .light, darkenMix: 0.04)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .dark, darkenMix: 0.05)
    }

    func testTransparentGhosttyBackgroundUsesCompositedOmnibarPill() {
        let baseColor = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let themeBackground = GhosttyBackgroundTheme.color(backgroundColor: baseColor, opacity: 0.42)

        guard let actual = resolvedBrowserOmnibarPillBackgroundColor(
            for: .light,
            themeBackgroundColor: themeBackground
        ).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(actual.alphaComponent, 1.0, accuracy: 0.001)
    }

    private func assertResolvedColorMatchesExpectedBlend(
        for colorScheme: ColorScheme,
        darkenMix: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let expected = themeBackground.blended(withFraction: darkenMix, of: .black) ?? themeBackground

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expectedSRGB = expected.usingColorSpace(.sRGB),
            let themeSRGB = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expectedSRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expectedSRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expectedSRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expectedSRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(actual.redComponent, themeSRGB.redComponent, file: file, line: line)
    }
}
@MainActor
final class BrowserPanelProfileIsolationTests: XCTestCase {
    func testStaleDidFinishDoesNotRecordVisitIntoSwitchedProfileHistory() throws {
        let alternateProfile = try makeTemporaryBrowserPanelProfile(named: "Switched")
        let defaultStore = BrowserHistoryStore.shared
        let alternateStore = BrowserProfileStore.shared.historyStore(for: alternateProfile.id)
        defaultStore.clearHistory()
        alternateStore.clearHistory()
        defer {
            defaultStore.clearHistory()
            alternateStore.clearHistory()
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let staleWebView = panel.webView
        let staleDelegate = try XCTUnwrap(staleWebView.navigationDelegate)
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale-finish"))
        staleWebView.loadHTMLString(
            "<html><head><title>Stale</title></head><body>stale</body></html>",
            baseURL: staleURL
        )

        XCTAssertTrue(
            panel.switchToProfile(alternateProfile.id),
            "Expected profile switch to succeed, current=\(panel.profileID) requested=\(alternateProfile.id) exists=\(BrowserProfileStore.shared.profileDefinition(id: alternateProfile.id) != nil)"
        )
        defaultStore.clearHistory()
        alternateStore.clearHistory()

        staleDelegate.webView?(staleWebView, didFinish: nil)
        drainBrowserPanelMainQueue()

        XCTAssertTrue(
            defaultStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the old profile history store, found \(defaultStore.entries.map { $0.url })"
        )
        XCTAssertTrue(
            alternateStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the newly selected profile history store, found \(alternateStore.entries.map { $0.url })"
        )
    }
}
@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)

        // Without a mounted address-bar view holding its own focus lease, consuming
        // the durable request must not leave WebKit focus suppression latched.
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)
    }

    func testExplicitSelectAllRequestUpgradesPendingPreserveRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus(selectionIntent: .preserveFieldEditorSelection)
        let secondRequest = panel.requestAddressBarFocus(selectionIntent: .selectAll)

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .selectAll)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }

    func testMountedViewLeaseKeepsSuppressionAfterRequestAcknowledgement() {
        let panel = BrowserPanel(workspaceId: UUID())
        let owner = UUID()
        let requestId = panel.requestAddressBarFocus()

        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: owner, reason: "test.mount")
        )
        panel.acknowledgeAddressBarFocusRequest(requestId)

        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        XCTAssertTrue(
            panel.relinquishAddressBarViewFocusLease(owner: owner, reason: "test.unmount")
        )
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testStaleViewCannotReleaseReplacementViewFocusLease() {
        let panel = BrowserPanel(workspaceId: UUID())
        let staleOwner = UUID()
        let replacementOwner = UUID()

        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: staleOwner, reason: "test.stale.mount")
        )
        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: replacementOwner, reason: "test.replacement.mount")
        )
        XCTAssertTrue(
            panel.relinquishAddressBarViewFocusLease(owner: staleOwner, reason: "test.stale.unmount")
        )

        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        XCTAssertTrue(
            panel.relinquishAddressBarViewFocusLease(owner: replacementOwner, reason: "test.replacement.unmount")
        )
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testPendingRequestKeepsSuppressionWhileFocusedViewRemounts() {
        let panel = BrowserPanel(workspaceId: UUID())
        let owner = UUID()
        let requestId = panel.requestAddressBarFocus()

        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: owner, reason: "test.mount")
        )
        XCTAssertTrue(
            panel.relinquishAddressBarViewFocusLease(owner: owner, reason: "test.unmount")
        )
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testNewestPresentationOwnerSurvivesStaleReregistrationAndUnregister() {
        let panel = BrowserPanel(workspaceId: UUID())
        let staleOwner = UUID()
        let replacementOwner = UUID()

        XCTAssertTrue(panel.registerAddressBarViewPresentation(owner: staleOwner))
        XCTAssertTrue(panel.registerAddressBarViewPresentation(owner: replacementOwner))
        XCTAssertEqual(panel.currentAddressBarViewPresentationOwner, replacementOwner)

        XCTAssertFalse(panel.registerAddressBarViewPresentation(owner: staleOwner))
        XCTAssertEqual(panel.currentAddressBarViewPresentationOwner, replacementOwner)

        XCTAssertTrue(panel.unregisterAddressBarViewPresentation(owner: staleOwner))
        XCTAssertEqual(panel.currentAddressBarViewPresentationOwner, replacementOwner)
    }

    func testRemovingNewestPresentationPromotesSurvivingOwner() {
        let panel = BrowserPanel(workspaceId: UUID())
        let previousOwner = UUID()
        let newestOwner = UUID()

        XCTAssertTrue(panel.registerAddressBarViewPresentation(owner: previousOwner))
        XCTAssertTrue(panel.registerAddressBarViewPresentation(owner: newestOwner))
        XCTAssertTrue(panel.unregisterAddressBarViewPresentation(owner: newestOwner))

        XCTAssertEqual(panel.currentAddressBarViewPresentationOwner, previousOwner)
        XCTAssertTrue(panel.unregisterAddressBarViewPresentation(owner: previousOwner))
        XCTAssertNil(panel.currentAddressBarViewPresentationOwner)
    }

    func testFindTransitionDoesNotRestoreReleasedAddressBarSuppression() {
        let panel = BrowserPanel(workspaceId: UUID())
        let owner = UUID()

        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: owner, reason: "test.mount")
        )
        panel.startFind()
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.hideFind()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testWebViewHandoffRevokesEveryOverlappingViewLease() {
        let panel = BrowserPanel(workspaceId: UUID())
        let staleOwner = UUID()
        let activeOwner = UUID()
        let panelId = panel.id
        let blurNotification = expectation(description: "panel-wide address bar blur")
        let observer = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { notification in
            guard notification.object as? UUID == panelId else { return }
            blurNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = panel.requestAddressBarFocus(selectionIntent: .selectAll)
        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: staleOwner, reason: "test.stale.mount")
        )
        XCTAssertTrue(
            panel.acquireAddressBarViewFocusLease(owner: activeOwner, reason: "test.active.mount")
        )

        panel.endAddressBarFocusForWebViewHandoff(reason: "test.escape")

        wait(for: [blurNotification], timeout: 1)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
        XCTAssertEqual(panel.pendingAddressBarFocusSelectionIntent, .preserveFieldEditorSelection)
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
        XCTAssertFalse(
            panel.relinquishAddressBarViewFocusLease(owner: staleOwner, reason: "test.stale.unmount")
        )
        XCTAssertFalse(
            panel.relinquishAddressBarViewFocusLease(owner: activeOwner, reason: "test.active.unmount")
        )
    }
}
