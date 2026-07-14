import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct PendingClosedHistoryLegacyFallbackTests {
    @Test
    func pendingNewerHistoryBlocksLegacyBrowserFallback() async throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let closedBrowserId = try #require(manager.openBrowser(
            url: URL(string: "https://example.com/blocked-legacy-fallback")
        ))
        let browserPanel = try #require(workspace.panels[closedBrowserId] as? BrowserPanel)
        await drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        await drainMainQueue()
        #expect(workspace.panels[closedBrowserId] == nil)

        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let pendingPanelSnapshot = try #require(
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

        let didReopen = manager.reopenMostRecentlyClosedBrowserPanel()
        #expect(!didReopen, "A pending newer history item must block the older legacy browser fallback")
        #expect(workspace.panels[closedBrowserId] == nil)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
