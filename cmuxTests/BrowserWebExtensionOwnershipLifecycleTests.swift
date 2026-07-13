import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionOwnershipLifecycleTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func backgroundWorkspaceAttachPreservesVisibleActiveBrowser() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let destinationManager = TabManager(browserWebExtensionHost: support)
        let sourceManager = TabManager(browserWebExtensionHost: support)
        let destinationWorkspace = try #require(destinationManager.selectedWorkspace)
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        let destinationPane = try #require(destinationWorkspace.bonsplitController.allPaneIds.first)
        let sourcePane = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let visibleBrowser = try #require(destinationWorkspace.newBrowserSurface(
            inPane: destinationPane,
            focus: false
        ))
        let movedBrowser = try #require(sourceWorkspace.newBrowserSurface(inPane: sourcePane, focus: false))
        sourceWorkspace.focusPanel(movedBrowser.id)
        let destinationWindow = NSWindow()
        let destinationWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: destinationManager,
            window: destinationWindow
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: destinationWindowID)
            destinationManager.tabs.forEach { $0.teardownAllPanels() }
            sourceManager.tabs.forEach { $0.teardownAllPanels() }
            destinationWindow.close()
        }
        destinationWorkspace.focusPanel(visibleBrowser.id)
        #expect(support.activePanelID(in: destinationWindow) == visibleBrowser.id)
        let detachedWorkspace = try #require(sourceManager.detachWorkspace(tabId: sourceWorkspace.id))

        destinationManager.attachWorkspace(detachedWorkspace, select: false)

        #expect(destinationManager.selectedWorkspace === destinationWorkspace)
        #expect(support.activePanelID(in: destinationWindow) == visibleBrowser.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func fallbackWindowOrderPreservesLastFocusedNormalWindow() throws {
        let support = BrowserWebExtensionSupport()
        let firstPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let secondPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        firstWindow.contentView = firstPanel.webView
        secondWindow.contentView = secondPanel.webView
        defer {
            firstPanel.close()
            secondPanel.close()
            firstWindow.close()
            secondWindow.close()
        }
        support.register(panel: firstPanel)
        NSApp.activate()
        secondWindow.orderFront(nil)
        secondWindow.makeKey()
        #expect(secondWindow.isKeyWindow)
        support.register(panel: secondPanel)

        let unrelatedWindow = NSWindow()
        defer { unrelatedWindow.close() }
        support.noteWindowBecameKey(unrelatedWindow)

        #expect(support.normalWindowAdaptersInFocusOrder.first?.hostWindow === secondWindow)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func closedRecoverableTabDropsQueuedAndLaterMetadataChanges() async throws {
        let support = BrowserWebExtensionSupport()
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let window = NSWindow()
        window.contentView = panel.webView
        defer {
            support.unregister(panelID: panel.id)
            panel.close()
            window.close()
        }
        support.register(panel: panel)
        let invalidation = try #require(support.actionSnapshotInvalidationsByPanelID[panel.id])

        try #require(panel.setMuted(true))
        support.noteTabMetadataChanged(panelID: panel.id)
        _ = support.noteWindowClosed(window)
        let revisionAfterClose = invalidation.revision

        await Task.yield()
        await Task.yield()
        #expect(invalidation.revision == revisionAfterClose)

        try #require(panel.setMuted(false))
        support.noteTabMetadataChanged(panelID: panel.id)
        await Task.yield()
        await Task.yield()
        #expect(invalidation.revision == revisionAfterClose)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func activeMoveAndCloseWaitForAuthoritativeSelection() throws {
        let support = BrowserWebExtensionSupport()
        let firstPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let secondPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let thirdPanel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false,
            browserWebExtensionHost: support
        )
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let panels = [firstPanel, secondPanel, thirdPanel]
        defer {
            for panel in panels {
                support.unregister(panelID: panel.id)
                panel.close()
            }
            firstWindow.close()
            secondWindow.close()
        }
        for panel in panels {
            support.register(panel: panel)
            support.noteWindowChanged(panelID: panel.id, nativeWindow: firstWindow)
        }
        support.noteActivated(panelID: firstPanel.id)
        support.noteActivated(panelID: thirdPanel.id)
        support.noteActivated(panelID: secondPanel.id)

        support.noteWindowChanged(panelID: secondPanel.id, nativeWindow: secondWindow)

        #expect(support.activePanelID(in: firstWindow) == nil)
        #expect(support.activePanelID(in: secondWindow) == secondPanel.id)
        support.noteActivated(panelID: firstPanel.id)
        #expect(support.activePanelID(in: firstWindow) == firstPanel.id)

        support.noteWindowChanged(panelID: secondPanel.id, nativeWindow: firstWindow)
        support.noteActivated(panelID: secondPanel.id)
        support.unregister(panelID: secondPanel.id)

        #expect(support.activePanelID(in: firstWindow) == nil)
        support.noteActivated(panelID: thirdPanel.id)
        #expect(support.activePanelID(in: firstWindow) == thirdPanel.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func replacementWindowRestoresDockBrowserWithoutWorkspaceFallback() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            browserWebExtensionHost: support,
            allowsStartupSessionRestore: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let workspacePaneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let workspaceBrowser = try #require(workspace.newBrowserSurface(
            inPane: workspacePaneID,
            focus: true
        ))
        let originalWindow = NSWindow()
        let replacementWindow = NSWindow()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: originalWindow
        )
        let dock = appDelegate.windowDock(forWindowId: windowID)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            manager.tabs.forEach { $0.teardownAllPanels() }
            originalWindow.close()
            replacementWindow.close()
        }
        let dockPaneID = try #require(dock.resolvePane(requestedPaneID: nil))
        let dockBrowserID = try #require(dock.newSurface(
            kind: .browser,
            inPane: dockPaneID,
            focus: true
        ))
        dock.reconcileBrowserWebExtensionWindows(in: originalWindow)
        support.noteActivated(panelID: dockBrowserID)
        let workspaceInvalidation = try #require(
            support.actionSnapshotInvalidationsByPanelID[workspaceBrowser.id]
        )
        let workspaceRevisionBeforeReplacement = workspaceInvalidation.revision
        let context = try #require(appDelegate.contextForMainTerminalWindow(originalWindow))

        appDelegate.registerMainWindow(
            replacementWindow,
            windowId: windowID,
            tabManager: manager,
            sidebarState: context.sidebarState,
            sidebarSelectionState: context.sidebarSelectionState,
            fileExplorerState: context.fileExplorerState,
            cmuxConfigStore: context.cmuxConfigStore
        )

        // The workspace tab is invalidated once when the old window closes and
        // once when the restored Dock tab replaces it as the authoritative active tab.
        #expect(workspaceInvalidation.revision == workspaceRevisionBeforeReplacement + 2)
        #expect(support.activePanelID(in: replacementWindow) == dockBrowserID)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func backgroundDockClosePreservesMainWorkspaceExtensionActiveTab() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            browserWebExtensionHost: support,
            allowsStartupSessionRestore: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let workspacePaneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let mainBrowser = try #require(workspace.newBrowserSurface(
            inPane: workspacePaneID,
            focus: true
        ))
        let window = NSWindow()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: window
        )
        let dock = appDelegate.windowDock(forWindowId: windowID)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            manager.tabs.forEach { $0.teardownAllPanels() }
            window.close()
        }
        let dockPaneID = try #require(dock.resolvePane(requestedPaneID: nil))
        let remainingDockBrowserID = try #require(
            dock.newSurface(kind: .browser, inPane: dockPaneID, focus: true)
        )
        let closingDockBrowserID = try #require(
            dock.newSurface(kind: .browser, inPane: dockPaneID, focus: true)
        )
        let closingDockTab = try #require(dock.surfaceId(forPanelId: closingDockBrowserID))
        dock.setVisibleInUI(true)
        dock.reconcileBrowserWebExtensionWindows(in: window)
        support.noteActivated(panelID: mainBrowser.id)
        #expect(support.activePanelID(in: window) == mainBrowser.id)

        dock.bonsplitController.delegate = nil
        #expect(dock.bonsplitController.closeTab(closingDockTab))
        dock.bonsplitController.delegate = dock
        dock.splitTabBar(dock.bonsplitController, didCloseTab: closingDockTab, fromPane: dockPaneID)

        #expect(support.activePanelID(in: window) == mainBrowser.id)

        let activeClosingDockBrowserID = try #require(
            dock.newSurface(kind: .browser, inPane: dockPaneID, focus: true)
        )
        let activeClosingDockTab = try #require(
            dock.surfaceId(forPanelId: activeClosingDockBrowserID)
        )
        support.noteActivated(panelID: activeClosingDockBrowserID)
        dock.bonsplitController.delegate = nil
        #expect(dock.bonsplitController.closeTab(activeClosingDockTab))
        dock.bonsplitController.delegate = dock
        dock.splitTabBar(
            dock.bonsplitController,
            didCloseTab: activeClosingDockTab,
            fromPane: dockPaneID
        )

        #expect(support.activePanelID(in: window) == remainingDockBrowserID)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func closingOwnerDoesNotRebindPanelThroughStaleWebViewWindow() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let manager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        let window = NSWindow()
        window.contentView = panel.webView
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: window
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            workspace.teardownAllPanels()
            window.close()
        }
        #expect(support.windowAdapter(for: panel.id)?.hostWindow === window)

        _ = manager.setOwningWindow(nil)
        #expect(panel.webView.window === window)
        #expect(support.windowAdapter(for: panel.id) == nil)

        support.noteActivated(panelID: panel.id)

        #expect(support.windowAdapter(for: panel.id) == nil)
        #expect(support.webExtensionWindow(for: window) == nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func attachmentRestoresWorkspaceFocusedBrowserInsteadOfDictionaryOrder() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let manager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        _ = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        let browsersInDictionaryOrder = workspace.panels.values.compactMap { $0 as? BrowserPanel }
        #expect(browsersInDictionaryOrder.count == 2)
        let focusedBrowser = try #require(browsersInDictionaryOrder.last)
        #expect(focusedBrowser !== browsersInDictionaryOrder.first)
        workspace.focusPanel(focusedBrowser.id)
        manager.pendingBrowserWebExtensionActivePanelID = UUID()

        let window = NSWindow()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: window
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            workspace.teardownAllPanels()
            window.close()
        }

        #expect(workspace.focusedPanelId == focusedBrowser.id)
        #expect(support.activePanelID(in: window) == focusedBrowser.id)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func orphanRecoveryPreservesPanelRegistrationForReattachment() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        let manager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        _ = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        let browser = try #require(workspace.newBrowserSurface(inPane: pane, focus: false))
        let originalWindow = NSWindow()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: manager,
            window: originalWindow
        )
        let context = try #require(appDelegate.contextForMainTerminalWindow(originalWindow))
        let replacementWindow = NSWindow()
        defer {
            manager.discardBrowserWebExtensionWindowOwnership()
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
            workspace.teardownAllPanels()
            originalWindow.close()
            replacementWindow.close()
        }

        appDelegate.discardOrphanedMainWindowContext(context)

        #expect(appDelegate.recoverableMainWindowRoute(windowId: windowID) != nil)
        #expect(support.tabAdapters[browser.id] != nil)
        #expect(support.windowAdapter(for: browser.id) == nil)

        _ = manager.setOwningWindow(replacementWindow)

        #expect(support.windowAdapter(for: browser.id)?.hostWindow === replacementWindow)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func recoverableRouteDoesNotDiscardBrowserMovedToLiveWindow() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let support = BrowserWebExtensionSupport()
        var sourceManager: TabManager? = TabManager(browserWebExtensionHost: support)
        let sourceWorkspace = try #require(sourceManager?.selectedWorkspace)
        let sourcePane = try #require(sourceWorkspace.bonsplitController.allPaneIds.first)
        let browser = try #require(sourceWorkspace.newBrowserSurface(inPane: sourcePane, focus: false))
        let sourceWindowID = UUID()
        let sourceWindow = NSWindow()
        appDelegate.rememberRecoverableMainWindowRoute(
            windowId: sourceWindowID,
            tabManager: try #require(sourceManager),
            window: sourceWindow
        )
        let route = try #require(appDelegate.recoverableMainWindowRoute(windowId: sourceWindowID))

        let destinationManager = TabManager(browserWebExtensionHost: support)
        let destinationWindow = NSWindow()
        let destinationWindowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: destinationManager,
            window: destinationWindow
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: destinationWindowID)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: sourceWindowID)
            destinationManager.tabs.forEach { $0.teardownAllPanels() }
            sourceWindow.close()
            destinationWindow.close()
        }

        let movedWorkspace = try #require(sourceManager?.detachWorkspace(tabId: sourceWorkspace.id))
        destinationManager.attachWorkspace(movedWorkspace, select: false)

        #expect(!route.browserPanelIDs.contains(browser.id))
        sourceManager = nil
        #expect(route.tabManager == nil)

        route.discardBrowserWebExtensionWindowOwnership()

        #expect(support.tabAdapters[browser.id] != nil)
        #expect(support.windowAdapter(for: browser.id)?.hostWindow === destinationWindow)
    }
}
