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
