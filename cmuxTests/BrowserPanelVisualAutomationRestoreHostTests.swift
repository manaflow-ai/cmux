import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func drainBrowserPanelVisualAutomationMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 1.0)
}

@MainActor
final class BrowserPanelVisualAutomationRestoreHostTests: XCTestCase {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testRestoredDiscardedHiddenWebViewGetsRestoreHostBeforeOffscreenCapture() {
        let hiddenAt = Date()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "data:text/html,<html><body>restore-host</body></html>")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(2.0)
        while (panel.webView.isLoading || panel.isLoading),
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for data URL to finish loading")
        XCTAssertFalse(panel.isLoading, "Timed out waiting for panel loading state to finish")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: hiddenAt)
        let originalWebView = panel.webView

        XCTAssertTrue(
            panel.discardHiddenWebViewForMemory(reason: "test.discard", now: hiddenAt),
            "blockers: \(panel.hiddenWebViewDiscardSnapshot)"
        )
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

    func testAutomationCommandLeaseTemporarilyHostsHiddenPortalWebViewOffscreen() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)
        BrowserWindowPortalRegistry.bind(webView: panel.webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        drainBrowserPanelVisualAutomationMainQueue()

        guard let originalSuperview = panel.webView.superview else {
            XCTFail("Expected portal-hosted webview")
            return
        }

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: Date())
        BrowserWindowPortalRegistry.updateEntryVisibility(for: panel.webView, visibleInUI: false, zPriority: 0)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        drainBrowserPanelVisualAutomationMainQueue()

        XCTAssertTrue(panel.webView.superview === originalSuperview)
        XCTAssertTrue(panel.webView.isHiddenOrHasHiddenAncestor)

        let lease = panel.beginAutomationCommandLease(reason: "test.automation")
        XCTAssertNotNil(lease)
        XCTAssertFalse(panel.webView.superview === originalSuperview)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertFalse(panel.webView.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(
            panel.discardHiddenWebViewForMemory(reason: "test.discardWhileAutomating"),
            "Socket automation must block hidden-webview discard while it owns the temporary host"
        )

        panel.endAutomationCommandLease(lease, reason: "test.automation")

        XCTAssertTrue(panel.webView.superview === originalSuperview)
        XCTAssertTrue(panel.webView.isHiddenOrHasHiddenAncestor)
    }

    func testAutomationCommandLeaseRestoresDiscardedHiddenWebViewBeforeHosting() {
        let hiddenAt = Date()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "data:text/html,<html><body>socket-restore</body></html>")!,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        let deadline = Date().addingTimeInterval(2.0)
        while (panel.webView.isLoading || panel.isLoading),
              RunLoop.main.run(mode: .default, before: deadline),
              Date() < deadline {}
        XCTAssertFalse(panel.webView.isLoading, "Timed out waiting for data URL to finish loading")
        XCTAssertFalse(panel.isLoading, "Timed out waiting for panel loading state to finish")

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: hiddenAt)
        let originalWebView = panel.webView

        XCTAssertTrue(
            panel.discardHiddenWebViewForMemory(reason: "test.discard", now: hiddenAt),
            "blockers: \(panel.hiddenWebViewDiscardSnapshot)"
        )
        XCTAssertFalse(panel.webView === originalWebView)
        XCTAssertNil(panel.webView.superview)
        XCTAssertEqual(panel.webViewLifecycleState, .discarded)

        let restoredWebView = panel.webView
        let lease = panel.beginAutomationCommandLease(reason: "test.automation")
        XCTAssertNotNil(lease)
        XCTAssertTrue(panel.webView === restoredWebView)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
        XCTAssertNotNil(panel.webView.window)
        XCTAssertFalse(panel.webView.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(
            panel.discardHiddenWebViewForMemory(reason: "test.discardWhileAutomating"),
            "Socket automation must block hidden-webview discard after restoring the replacement webview"
        )

        panel.endAutomationCommandLease(lease, reason: "test.automation")

        XCTAssertNil(panel.webView.superview)
        XCTAssertEqual(panel.webViewLifecycleState, .liveHidden)
    }
}
