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
    @Test("Delayed workspace host cannot reclaim a terminal after Dock handoff")
    @MainActor
    func delayedWorkspaceHostCannotReclaimTerminalAfterDockHandoff() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let sourceHost = NSView()
        let dockHost = NSView()
        let sourcePane = PaneID()
        let dockPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(sourceHost),
            paneId: sourcePane,
            instanceSerial: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.initial"
        ))
        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.handoff"
        ))

        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(sourceHost),
            paneId: sourcePane,
            instanceSerial: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.delayedCallback"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == dockPane.id)
    }

    @Test("Detached replacement cannot displace a rearmed Dock portal host")
    @MainActor
    func detachedReplacementCannotDisplaceRearmedDockPortalHost() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let liveHost = NSView()
        let detachedReplacement = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(liveHost),
            paneId: pane,
            instanceSerial: 1,
            ownershipGeneration: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.liveHost"
        ))
        #expect(panel.surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(liveHost),
            instanceSerial: 1,
            reason: "test.dock.liveHostDismantled"
        ))

        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(detachedReplacement),
            paneId: pane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: false,
            bounds: .zero,
            reason: "test.dock.detachedReplacement"
        ))
        #expect(
            panel.surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(liveHost))
        )

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(detachedReplacement),
            paneId: pane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.attachedReplacement"
        ))
    }

    @Test("Detached browser destination cannot displace its live source host")
    @MainActor
    func detachedBrowserDestinationCannotDisplaceLiveSourceHost() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }
        let liveSourceHost = NSView()
        let detachedDestinationHost = NSView()
        let laterSamePaneHost = NSView()
        let sourcePane = PaneID()
        let destinationPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 210, height: 510)

        #expect(panel.claimPortalHost(
            hostId: ObjectIdentifier(liveSourceHost),
            paneId: sourcePane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.liveSource"
        ))
        panel.preparePortalHostReplacementForNextDistinctClaim(
            inPane: destinationPane,
            reason: "test.dock.browser.moveRearm"
        )

        #expect(!panel.claimPortalHost(
            hostId: ObjectIdentifier(detachedDestinationHost),
            paneId: destinationPane,
            inWindow: false,
            bounds: .zero,
            reason: "test.dock.browser.detachedDestination"
        ))
        #expect(panel.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(liveSourceHost),
            reason: "test.dock.browser.sourceDismantled"
        ))
        #expect(!panel.claimPortalHost(
            hostId: ObjectIdentifier(detachedDestinationHost),
            paneId: destinationPane,
            inWindow: false,
            bounds: .zero,
            reason: "test.dock.browser.detachedDestinationAfterSourceRelease"
        ))

        #expect(panel.claimPortalHost(
            hostId: ObjectIdentifier(detachedDestinationHost),
            paneId: destinationPane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.attachedDestination"
        ))
        #expect(!panel.claimPortalHost(
            hostId: ObjectIdentifier(laterSamePaneHost),
            paneId: destinationPane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.laterSamePaneHost"
        ))

        let survivingPanel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { survivingPanel.close() }
        let survivingHost = NSView()
        let survivingPane = PaneID()
        let laterSurvivingPaneHost = NSView()

        #expect(survivingPanel.claimPortalHost(
            hostId: ObjectIdentifier(survivingHost),
            paneId: sourcePane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.survivingSource"
        ))
        survivingPanel.preparePortalHostReplacementForNextDistinctClaim(
            inPane: survivingPane,
            reason: "test.dock.browser.survivingMoveRearm"
        )
        #expect(survivingPanel.claimPortalHost(
            hostId: ObjectIdentifier(survivingHost),
            paneId: survivingPane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.survivingDestination"
        ))
        #expect(!survivingPanel.claimPortalHost(
            hostId: ObjectIdentifier(laterSurvivingPaneHost),
            paneId: survivingPane,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.browser.laterSurvivingPaneHost"
        ))
    }

    @Test("Newer stale workspace host is rejected by live Dock ownership")
    @MainActor
    func newerStaleWorkspaceHostIsRejectedByLiveDockOwnership() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let dockHost = NSView()
        let staleWorkspaceHost = NSView()
        let dockPane = PaneID()
        let staleWorkspacePane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 2,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.liveOwner"
        ))
        #expect(!panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(staleWorkspaceHost),
            paneId: staleWorkspacePane,
            instanceSerial: 3,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            allowsAuthorityAcquisition: false,
            reason: "test.workspace.modelIneligible"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == dockPane.id)
    }

    @Test("New model ownership permits rollback to an earlier host")
    @MainActor
    func newModelOwnershipPermitsRollbackToEarlierHost() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }
        let workspaceHost = NSView()
        let dockHost = NSView()
        let workspacePane = PaneID()
        let dockPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(workspaceHost),
            paneId: workspacePane,
            instanceSerial: 10,
            ownershipGeneration: 1,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.beforeMove"
        ))
        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(dockHost),
            paneId: dockPane,
            instanceSerial: 20,
            ownershipGeneration: 2,
            inWindow: true,
            bounds: bounds,
            reason: "test.dock.move"
        ))
        panel.surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(dockHost),
            instanceSerial: 20,
            reason: "test.dock.rollback"
        )

        #expect(panel.surface.claimPortalHost(
            hostId: ObjectIdentifier(workspaceHost),
            paneId: workspacePane,
            instanceSerial: 10,
            ownershipGeneration: 3,
            inWindow: true,
            bounds: bounds,
            reason: "test.workspace.rollback"
        ))
        #expect(panel.surface.debugPortalHostLease().paneId == workspacePane.id)
    }

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

    @Test("Split attach repairs a placeholder-only source pane")
    @MainActor
    func splitAttachRepairsPlaceholderOnlySourcePane() throws {
        let sourceWorkspaceId = UUID()
        let browser = BrowserPanel(workspaceId: sourceWorkspaceId, renderInitialNavigation: false)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let detached = Self.detachedBrowserTransfer(panel: browser, sourceWorkspaceId: sourceWorkspaceId)

        let attachedPanelId = store.attachDetachedSurface(
            detached,
            bySplitting: rootPane,
            orientation: .horizontal,
            insertFirst: false,
            focus: true
        )

        #expect(attachedPanelId == browser.id)
        #expect(store.paneId(forPanelId: browser.id) != rootPane)
        let sourceTabs = store.bonsplitController.tabs(inPane: rootPane)
        #expect(!sourceTabs.isEmpty)
        #expect(sourceTabs.allSatisfy { store.panel(for: $0.id) != nil })
        #expect(sourceTabs.contains { store.panel(for: $0.id) is TerminalPanel })
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

    @Test("Portal follow-up observers are object-scoped and bounded")
    @MainActor
    func dockPortalFollowUpIsObjectScopedAndBounded() throws {
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
        let detached = Self.detachedBrowserTransfer(panel: browser, sourceWorkspaceId: sourceWorkspaceId)
        _ = try #require(store.attachDetachedSurface(detached, inPane: rootPane, focus: true))
        let window = Self.portalWindow()
        defer { Self.closePortalWindow(window) }
        browser.portalAnchorView.frame = .zero
        window.contentView?.addSubview(browser.portalAnchorView)

        store.clearDockPortalReconcile()
        store.scheduleDockPortalReconcile(reason: "test.boundedFollowUp")
        let wakeBudget = store.dockPortalReconcileState.layoutWakeAttemptsRemaining
        #expect(wakeBudget > 0)
        #expect(!store.dockPortalReconcileState.portalObservers.isEmpty)
        #expect(!store.dockPortalReconcileState.layoutObservers.isEmpty)

        NotificationCenter.default.post(
            name: .browserPortalRegistryDidChange,
            object: NSObject()
        )
        #expect(store.dockPortalReconcileState.layoutWakeAttemptsRemaining == wakeBudget)

        for _ in 0..<wakeBudget {
            NotificationCenter.default.post(
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }
        #expect(store.dockPortalReconcileState.layoutWakeAttemptsRemaining == 0)
        #expect(store.dockPortalReconcileState.layoutObservers.isEmpty)
        #expect(!store.dockPortalReconcileState.portalObservers.isEmpty)

        NotificationCenter.default.post(
            name: .browserPortalRegistryDidChange,
            object: browser.webView
        )
        #expect(store.dockPortalReconcileState.layoutWakeAttemptsRemaining == wakeBudget)
        #expect(!store.dockPortalReconcileState.layoutObservers.isEmpty)
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
