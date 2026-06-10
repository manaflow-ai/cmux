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
final class BrowserPanelVisualAutomationRestoreHostTests: XCTestCase {
    func testRestoredDiscardedHiddenWebViewGetsRestoreHostBeforeOffscreenCapture() {
        let discardedAt = Date(timeIntervalSince1970: 400)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(1.0)
        while panel.webView.isLoading,
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for about:blank to finish loading")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        XCTAssertTrue(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        XCTAssertFalse(panel.webView === originalWebView)
        XCTAssertNil(panel.webView.superview)
        XCTAssertFalse(panel.hasBackgroundPreloadHost)

        XCTAssertTrue(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertNil(panel.webView.superview)

        XCTAssertTrue(panel.ensureVisualAutomationRestoreHostIfNeeded(reason: "test.visualAutomation"))
        XCTAssertTrue(panel.hasBackgroundPreloadHost)
        XCTAssertNotNil(panel.webView.superview)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertFalse(panel.ensureVisualAutomationRestoreHostIfNeeded(reason: "test.visualAutomation.alreadyAttached"))
    }
}

