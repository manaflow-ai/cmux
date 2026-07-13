import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock portal reconcile", .serialized)
struct DockPortalReconcileTests {
    @Test("Browser attach into visible Dock shows portal")
    @MainActor
    func dockBrowserAttachIntoVisibleDockShowsPortal() throws {
        let sourceWorkspaceId = UUID()
        let browser = BrowserPanel(workspaceId: sourceWorkspaceId, renderInitialNavigation: false)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        Self.installBrowserAnchor(browser, in: window)
        BrowserWindowPortalRegistry.bind(
            webView: browser.webView,
            to: browser.portalAnchorView,
            visibleInUI: false,
            zPriority: 0
        )
        BrowserWindowPortalRegistry.synchronizeForAnchor(browser.portalAnchorView)
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.visibleInUI == false)

        let detached = Self.detachedBrowserTransfer(panel: browser, sourceWorkspaceId: sourceWorkspaceId)
        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: true)

        #expect(attachedPanelId == browser.id)
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.visibleInUI == true)
    }

    @Test("Browser reveal restores portal visibility")
    @MainActor
    func dockBrowserRevealRestoresPortalVisibility() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let panelId = try #require(store.newSurface(kind: .browser, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let browser = try #require(store.panel(for: tabId) as? BrowserPanel)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        Self.installBrowserAnchor(browser, in: window)
        BrowserWindowPortalRegistry.bind(
            webView: browser.webView,
            to: browser.portalAnchorView,
            visibleInUI: true,
            zPriority: 1
        )
        BrowserWindowPortalRegistry.synchronizeForAnchor(browser.portalAnchorView)

        store.setVisibleInUI(false)
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.visibleInUI == false)
        store.setVisibleInUI(true)

        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.visibleInUI == true)
    }

    @Test("Terminal stale portal bind reconciles without focus")
    @MainActor
    func dockTerminalStalePortalBindReconcilesWithoutFocus() throws {
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let terminal = try #require(store.panel(for: tabId) as? TerminalPanel)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 240, height: 160))
        window.contentView?.addSubview(anchor)
        TerminalWindowPortalRegistry.bind(
            hostedView: terminal.hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: terminal.surface.id,
            expectedGeneration: terminal.surface.portalBindingGeneration()
        )
        anchor.removeFromSuperview()
        let reattachTokenBefore = terminal.viewReattachToken

        store.reconcileDockPortalPass(reason: "test.dockPortalReconcile")

        #expect(terminal.viewReattachToken > reattachTokenBefore)
    }

    @Test("Browser unbound reconcile binds imperatively")
    @MainActor
    func dockBrowserUnboundReconcileBindsImperatively() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let panelId = try #require(store.newSurface(kind: .browser, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let browser = try #require(store.panel(for: tabId) as? BrowserPanel)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        Self.installBrowserAnchor(browser, in: window)
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView) == nil)

        store.reconcileDockPortalPass(reason: "test.dockPortalReconcile")

        #expect(BrowserWindowPortalRegistry.isWebView(browser.webView, boundTo: browser.portalAnchorView))
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.visibleInUI == true)
    }

    @Test("Healthy browser reconcile does not mutate portal registry")
    @MainActor
    func dockBrowserHealthyReconcileIsPortalNoOp() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let panelId = try #require(store.newSurface(kind: .browser, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let browser = try #require(store.panel(for: tabId) as? BrowserPanel)

        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        Self.installBrowserAnchor(browser, in: window)
        BrowserWindowPortalRegistry.bind(
            webView: browser.webView,
            to: browser.portalAnchorView,
            visibleInUI: true,
            zPriority: 1
        )
        BrowserWindowPortalRegistry.synchronizeForAnchor(browser.portalAnchorView)
        #expect(BrowserWindowPortalRegistry.isWebView(browser.webView, boundTo: browser.portalAnchorView))
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: browser.webView)?.containerHidden == false)

        var registryChangeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: browser.webView,
            queue: nil
        ) { _ in
            registryChangeCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.clearDockPortalReconcile()
        store.dockPortalReconcileState.scheduledRequestCount = 0
        store.applyVisibility(to: browser)
        #expect(store.dockPortalReconcileState.scheduledRequestCount == 0)

        let needsFollowUp = store.reconcileDockPortalPass(reason: "test.dockPortalReconcile")

        #expect(!needsFollowUp)
        #expect(registryChangeCount == 0)
    }

    @Test("Move into Dock schedules portal reconcile")
    @MainActor
    func moveIntoDockSchedulesPortalReconcile() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let sourcePanel = try #require(workspace.panels.values.first)
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))
            let dock = workspace.dockSplit
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
            dock.setVisibleInUI(true)
            dock.clearDockPortalReconcile()
            dock.dockPortalReconcileState.scheduledRequestCount = 0

            let moved = appDelegate.moveSurfaceIntoDock(
                sourceTabId: sourceTabId.uuid,
                destinationDock: dock,
                destination: .insert(targetPane: rootPane, targetIndex: nil)
            )

            #expect(moved)
            #expect(dock.dockPortalReconcileState.scheduledRequestCount > 0)
        }
    }

    @Test("Move Dock surface to workspace reconciles destination")
    @MainActor
    func moveDockSurfaceToWorkspaceReconcilesDestination() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let sourceWorkspace = try #require(manager.tabs.first)
            let destinationWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
            let dock = sourceWorkspace.dockSplit
            let rootPane = try #require(dock.bonsplitController.allPaneIds.first)
            dock.setVisibleInUI(true)
            let dockPanelId = try #require(dock.newSurface(kind: .terminal, inPane: rootPane, focus: true))
            dock.clearDockPortalReconcile()
            dock.dockPortalReconcileState.scheduledRequestCount = 0

            let moved = appDelegate.moveDockSurfaceToWorkspace(
                sourceDock: dock,
                panelId: dockPanelId,
                toWorkspace: destinationWorkspace.id,
                targetPane: nil,
                targetIndex: nil,
                splitTarget: nil,
                focus: true,
                focusWindow: false
            )

            #expect(moved)
            #expect(destinationWorkspace.panels[dockPanelId] != nil)
            #expect(dock.dockPortalReconcileState.scheduledRequestCount > 0)
        }
    }

    @MainActor
    private static func detachedBrowserTransfer(
        panel: BrowserPanel,
        sourceWorkspaceId: UUID
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "browser",
            isLoading: panel.isLoading,
            isPinned: false,
            directory: nil,
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: panel.displayTitle,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            restoredAgentCompletedGeneration: nil,
            shellActivityState: nil,
            restoredResumeSessionWorkingDirectory: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    @MainActor
    private static func portalWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private static func closePortalWindow(_ window: NSWindow) {
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        window.orderOut(nil)
    }

    @MainActor
    private static func installBrowserAnchor(_ browser: BrowserPanel, in window: NSWindow) {
        browser.portalAnchorView.frame = NSRect(x: 24, y: 24, width: 240, height: 160)
        window.contentView?.addSubview(browser.portalAnchorView)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
