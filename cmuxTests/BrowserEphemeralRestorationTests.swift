import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserEphemeralRestorationTests {
    @Test
    func dockBrowserInstallsAppLinkHandoffAction() {
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        let panel = dock.makeBrowserPanel(
            url: URL(string: "https://cmux.test/app-pro-welcome")
        )
        defer { panel.close() }

        #expect(panel.openAppLinkInBrowserSplit != nil)
    }

    @Test
    func attachingMovedBrowserRebindsAppLinkHandoffAction() throws {
        let sourceDock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        sourceDock.hasLoadedConfiguration = true
        let sourcePaneID = try #require(
            sourceDock.bonsplitController.allPaneIds.first
        )
        let panelID = try #require(sourceDock.newSurface(
            kind: .browser,
            inPane: sourcePaneID,
            url: URL(string: "https://cmux.test/app-pro-welcome"),
            focus: false
        ))
        let panel = try #require(sourceDock.browserPanel(for: panelID))
        let detached = try #require(sourceDock.detachSurface(panelId: panelID))
        var staleHandlerCalled = false
        panel.openAppLinkInBrowserSplit = { _ in
            staleHandlerCalled = true
            return false
        }

        let destinationDock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { false }
        )
        destinationDock.hasLoadedConfiguration = true
        defer { destinationDock.closeAllPanels() }
        let destinationPaneID = try #require(
            destinationDock.bonsplitController.allPaneIds.first
        )
        _ = try #require(destinationDock.attachDetachedSurface(
            detached,
            inPane: destinationPaneID,
            focus: false
        ))

        let handoffAction = try #require(
            panel.openAppLinkInBrowserSplit
        )
        _ = handoffAction(
            URL(string: "https://cmux.test/dashboard/testflight")!
        )

        #expect(!staleHandlerCalled)
    }

    @Test
    func explicitEphemeralPanelDoesNotUsePersistentProfileHistory() throws {
        let profileID = BrowserProfileStore.shared.builtInDefaultProfileID
        let persistentStore = BrowserProfileStore.shared.historyStore(for: profileID)
        persistentStore.clearHistory()
        defer { persistentStore.clearHistory() }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: profileID,
            renderInitialNavigation: false,
            websiteDataStore: .nonPersistent()
        )
        let privateURL = try #require(
            URL(string: "https://example.com/account-private-history")
        )

        panel.historyStore.recordVisit(url: privateURL, title: "Private")

        #expect(panel.historyStore !== persistentStore)
        #expect(panel.historyStore.entries.map(\.url) == [privateURL.absoluteString])
        #expect(persistentStore.entries.isEmpty)
    }

    @Test
    func sessionSnapshotExcludesNonPersistentBrowser() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let browser = try #require(workspace.newBrowserSurface(
            inPane: pane,
            url: URL(string: "https://example.com/authenticated-handoff"),
            focus: false,
            websiteDataStore: .nonPersistent()
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        #expect(!snapshot.panels.contains { $0.id == browser.id })
    }

    @Test
    func duplicatePreservesNonPersistentStore() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let browserPanel = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            url: URL(string: "https://example.com/authenticated-handoff"),
            focus: true,
            websiteDataStore: websiteDataStore
        ))

        let duplicate = try #require(
            workspace.duplicateBrowserToRight(panelId: browserPanel.id, focus: false)
        )

        #expect(duplicate.websiteDataStore === websiteDataStore)
        #expect(duplicate.webView.configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func dockBrowserAcceptsNonPersistentStore() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let paneID = try #require(dock.bonsplitController.allPaneIds.first)
        let websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let panelID = try #require(dock.newSurface(
            kind: .browser,
            inPane: paneID,
            url: URL(string: "https://example.com/authenticated-handoff"),
            focus: false,
            websiteDataStore: websiteDataStore
        ))
        let panel = try #require(dock.browserPanel(for: panelID))

        #expect(panel.websiteDataStore === websiteDataStore)
        #expect(panel.webView.configuration.websiteDataStore === websiteDataStore)
    }

    @Test
    func closingNonPersistentBrowserDoesNotRecordRestoreState() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let workspace = Workspace()
        let expectedURL = try #require(
            URL(string: "https://example.com/authenticated-handoff")
        )
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let browserPanel = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            url: expectedURL,
            focus: false,
            websiteDataStore: .nonPersistent()
        ))
        let tabID = try #require(workspace.surfaceIdFromPanelId(browserPanel.id))
        let tab = try #require(workspace.bonsplitController.tab(tabID))
        var legacySnapshot: ClosedBrowserPanelRestoreSnapshot?
        workspace.onClosedBrowserPanel = { legacySnapshot = $0 }
        workspace.markCloseHistoryEligible(panelId: browserPanel.id)

        #expect(workspace.splitTabBar(
            workspace.bonsplitController,
            shouldCloseTab: tab,
            inPane: paneID
        ))
        workspace.splitTabBar(
            workspace.bonsplitController,
            didCloseTab: tabID,
            fromPane: paneID
        )

        #expect(!ClosedItemHistoryStore.shared.canReopen)
        #expect(legacySnapshot == nil)
    }
}
