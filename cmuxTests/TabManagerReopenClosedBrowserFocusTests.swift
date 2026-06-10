import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class TabManagerReopenClosedBrowserFocusTests: XCTestCase {
    func testStandardBrowserTabCloseStagesRestoreSnapshot() {
        let workspace = Workspace()
        let expectedURL = URL(string: "https://example.com/standard-close")
        guard let paneId = workspace.bonsplitController.focusedPaneId,
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, url: expectedURL, focus: false),
              let tabId = workspace.surfaceIdFromPanelId(browserPanel.id),
              let tab = workspace.bonsplitController.tab(tabId) else {
            XCTFail("Expected browser panel setup")
            return
        }

        var closedSnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { snapshot in
            closedSnapshot = snapshot
        }

        XCTAssertTrue(workspace.splitTabBar(workspace.bonsplitController, shouldCloseTab: tab, inPane: paneId))
        workspace.splitTabBar(workspace.bonsplitController, didCloseTab: tabId, fromPane: paneId)

        XCTAssertEqual(closedSnapshot?.workspaceId, workspace.id)
        XCTAssertEqual(closedSnapshot?.url, expectedURL)
        XCTAssertEqual(closedSnapshot?.originalPaneId, paneId.id)
    }

    func testTemporaryDiffViewerTabCloseDoesNotStageRestoreSnapshot() throws {
        let workspace = Workspace()
        let diffViewerURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152/token/diff.html#cmux-diff-viewer"))
        guard let paneId = workspace.bonsplitController.focusedPaneId,
              let browserPanel = workspace.newBrowserSurface(inPane: paneId, url: diffViewerURL, focus: false),
              let tabId = workspace.surfaceIdFromPanelId(browserPanel.id),
              let tab = workspace.bonsplitController.tab(tabId) else {
            XCTFail("Expected diff viewer browser panel setup")
            return
        }

        var closedSnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { snapshot in
            closedSnapshot = snapshot
        }

        XCTAssertTrue(workspace.splitTabBar(workspace.bonsplitController, shouldCloseTab: tab, inPane: paneId))
        workspace.splitTabBar(workspace.bonsplitController, didCloseTab: tabId, fromPane: paneId)

        XCTAssertNil(closedSnapshot)
    }

    func testBrowserWebViewDidCloseClosesPanelAndCmdShiftTRestoresIt() {
        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/self-close")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        let panelIdsAfterClose = Set(workspace.panels.keys)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsAfterClose),
              let reopenedPanel = workspace.panels[reopenedPanelId] as? BrowserPanel else {
            XCTFail("Expected Cmd+Shift+T to restore the self-closed browser panel")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
    }

    func testReopenClosedItemFallsBackToLegacyClosedBrowserStack() {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/self-close-item-fallback")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)

        XCTAssertTrue(appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: manager))
        drainMainQueue()

        guard let reopenedPanel = workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            XCTFail("Expected reopened browser panel")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
    }

    func testReopenClosedItemUsesNewerLegacyBrowserBeforeOlderClosedStore() throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/newer-legacy-browser")
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        var olderPanelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        olderPanelSnapshot.customTitle = "Older Stored Panel"
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: paneId.id,
                tabIndex: 0,
                snapshot: olderPanelSnapshot
            ))
        ))

        guard let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        let panelIdsAfterClose = Set(workspace.panels.keys)

        XCTAssertTrue(appDelegate.reopenMostRecentlyClosedItem(
            preferredTabManager: manager,
            shouldActivate: false
        ))
        drainMainQueue()

        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsAfterClose),
              let reopenedPanel = workspace.panels[reopenedPanelId] as? BrowserPanel else {
            XCTFail("Expected Cmd+Shift+T to restore the newer self-closed browser before the older stored tab")
            return
        }
        XCTAssertEqual(reopenedPanel.currentURL, expectedURL)
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)
    }

    func testClearRecentlyClosedHistoryClearsLegacyBrowserStack() {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let expectedURL = URL(string: "https://example.com/clear-legacy-reopen")
        guard let workspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: expectedURL),
              let browserPanel = workspace.panels[closedBrowserId] as? BrowserPanel else {
            XCTFail("Expected browser panel setup")
            return
        }

        drainMainQueue()
        browserPanel.webView.uiDelegate?.webViewDidClose?(browserPanel.webView)
        drainMainQueue()

        XCTAssertNil(workspace.panels[closedBrowserId])
        appDelegate.clearRecentlyClosedHistory(preferredTabManager: manager)

        XCTAssertFalse(appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: manager))
    }

    func testReopenFromDifferentWorkspaceFocusesReopenedBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/ws-switch")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenDropsBrowserSnapshotWhenOriginalWorkspaceDeleted() {
        let manager = TabManager()
        guard let originalWorkspace = manager.selectedWorkspace,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/deleted-ws")) else {
            XCTFail("Expected initial workspace and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(originalWorkspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let currentWorkspace = manager.addWorkspace()
        let currentPanelCountBefore = currentWorkspace.panels.count
        manager.closeWorkspace(originalWorkspace, recordHistory: false)

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(manager.tabs.contains(where: { $0.id == originalWorkspace.id }))

        XCTAssertFalse(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertEqual(currentWorkspace.panels.count, currentPanelCountBefore)
        XCTAssertFalse(isFocusedPanelBrowser(in: currentWorkspace))
    }

    func testReopenCollapsedSplitFromDifferentWorkspaceFocusesBrowser() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let sourcePanelId = workspace1.focusedPanelId,
              let splitBrowserId = manager.newBrowserSplit(
                tabId: workspace1.id,
                fromPanelId: sourcePanelId,
                orientation: .horizontal,
                insertFirst: false,
                url: URL(string: "https://example.com/collapsed-split")
              ) else {
            XCTFail("Expected to create browser split")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(splitBrowserId, force: true))
        drainMainQueue()

        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertTrue(isFocusedPanelBrowser(in: workspace1))
    }

    func testReopenFromDifferentWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace1 = manager.selectedWorkspace,
              let preReopenPanelId = workspace1.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-cross-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace1.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace1.panels.keys)
        let workspace2 = manager.addWorkspace()
        XCTAssertEqual(manager.selectedTabId, workspace2.id)

        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace1, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace1.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace1.id)
        XCTAssertEqual(workspace1.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace1.panels[reopenedPanelId] is BrowserPanel)
    }

    func testReopenInSameWorkspaceWinsAgainstSingleDeferredStaleFocus() {
        let manager = TabManager()
        guard let workspace = manager.selectedWorkspace,
              let preReopenPanelId = workspace.focusedPanelId,
              let closedBrowserId = manager.openBrowser(url: URL(string: "https://example.com/stale-focus-same-ws")) else {
            XCTFail("Expected initial workspace state and browser panel")
            return
        }

        drainMainQueue()
        XCTAssertTrue(workspace.closePanel(closedBrowserId, force: true))
        drainMainQueue()

        let panelIdsBeforeReopen = Set(workspace.panels.keys)
        XCTAssertTrue(manager.reopenMostRecentlyClosedBrowserPanel())
        guard let reopenedPanelId = singleNewPanelId(in: workspace, comparedTo: panelIdsBeforeReopen) else {
            XCTFail("Expected reopened browser panel ID")
            return
        }

        // Simulate one delayed stale focus callback from the panel that was focused before reopen.
        DispatchQueue.main.async {
            workspace.focusPanel(preReopenPanelId)
        }

        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, reopenedPanelId)
        XCTAssertTrue(workspace.panels[reopenedPanelId] is BrowserPanel)
    }

    private func isFocusedPanelBrowser(in workspace: Workspace) -> Bool {
        guard let focusedPanelId = workspace.focusedPanelId else { return false }
        return workspace.panels[focusedPanelId] is BrowserPanel
    }

    private func singleNewPanelId(in workspace: Workspace, comparedTo previousPanelIds: Set<UUID>) -> UUID? {
        let newPanelIds = Set(workspace.panels.keys).subtracting(previousPanelIds)
        guard newPanelIds.count == 1 else { return nil }
        return newPanelIds.first
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        let result = XCTWaiter().wait(for: [expectation], timeout: 3.0)
        XCTAssertEqual(result, .completed)
    }
}

