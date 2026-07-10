import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PendingClosedHistoryLegacyFallbackTests: XCTestCase {
    func testPendingNewerHistoryBlocksLegacyBrowserFallback() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let closedBrowserId = try XCTUnwrap(manager.openBrowser(
            url: URL(string: "https://example.com/blocked-legacy-fallback")
        ))
        let browserPanel = try XCTUnwrap(workspace.panels[closedBrowserId] as? BrowserPanel)
        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()
        XCTAssertNil(workspace.panels[closedBrowserId])

        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let pendingPanelSnapshot = try XCTUnwrap(
            workspace.sessionSnapshot(includeScrollback: false).panels.first
        )
        ClosedItemHistoryStore.shared.pushPendingEnrichment(ClosedItemHistoryRecord(
            closedAt: .distantFuture,
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: paneId.id,
                tabIndex: 0,
                snapshot: pendingPanelSnapshot
            ))
        ))

        guard !manager.reopenMostRecentlyClosedBrowserPanel() else {
            XCTFail("A pending newer history item must block the older legacy browser fallback")
            return
        }
        XCTAssertNil(workspace.panels[closedBrowserId])
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 3), .completed)
    }
}
