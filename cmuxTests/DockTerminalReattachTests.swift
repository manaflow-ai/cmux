import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockSocketLifecycleTests {
    @MainActor
    private func detachedTerminalTransfer(
        panel: TerminalPanel,
        sourceWorkspaceId: UUID
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: nil,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: nil,
            resumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    @Test("Live terminal attach into Dock requests a view reattach")
    @MainActor
    func liveTerminalAttachIntoDockRequestsViewReattach() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId
        )
        let reattachTokenBefore = panel.viewReattachToken

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)

        #expect(attachedPanelId == panel.id)
        #expect(panel.workspaceId == store.workspaceId)
        #expect(panel.surface.focusPlacement == .rightSidebarDock)
        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }

    @Test("Focused live terminal attach into visible Dock requests one view reattach")
    @MainActor
    func focusedLiveTerminalAttachIntoVisibleDockRequestsOneViewReattach() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId
        )
        let reattachTokenBefore = panel.viewReattachToken

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: true)

        #expect(attachedPanelId == panel.id)
        #expect(panel.hostedView.debugPortalVisibleInUI)
        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }

    @Test("Hidden terminal attach into visible Dock requests one view reattach")
    @MainActor
    func hiddenTerminalAttachIntoVisibleDockRequestsOneViewReattach() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        panel.hostedView.setVisibleInUI(false)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        store.setVisibleInUI(true)
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId
        )
        let reattachTokenBefore = panel.viewReattachToken

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: true)

        #expect(attachedPanelId == panel.id)
        #expect(panel.hostedView.debugPortalVisibleInUI)
        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }

    @Test("Visible detached Dock terminal requests a view reattach")
    @MainActor
    func visibleDetachedDockTerminalRequestsViewReattach() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let panel = try #require(store.panel(for: tabId) as? TerminalPanel)
        store.setVisibleInUI(true)
        panel.hostedView.setVisibleInUI(true)
        TerminalWindowPortalRegistry.detach(hostedView: panel.hostedView)
        #expect(!panel.hostedView.isHidden)
        #expect(TerminalWindowPortalRegistry.updateEntryVisibility(for: panel.hostedView, visibleInUI: true))
        let reattachTokenBefore = panel.viewReattachToken

        store.focusPanel(panelId)

        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }

    @Test("Visible Dock terminal with stale portal anchor requests a view reattach")
    @MainActor
    func visibleDockTerminalWithStalePortalAnchorRequestsViewReattach() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let panel = try #require(store.panel(for: tabId) as? TerminalPanel)
        store.setVisibleInUI(true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 240, height: 160))
        contentView.addSubview(anchor)
        TerminalWindowPortalRegistry.bind(
            hostedView: panel.hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: panel.surface.id,
            expectedGeneration: panel.surface.portalBindingGeneration()
        )
        #expect(!TerminalWindowPortalRegistry.updateEntryVisibility(for: panel.hostedView, visibleInUI: true))
        anchor.removeFromSuperview()
        #expect(TerminalWindowPortalRegistry.updateEntryVisibility(for: panel.hostedView, visibleInUI: true))
        let reattachTokenBefore = panel.viewReattachToken

        store.focusPanel(panelId)

        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }

    @Test("Dock terminal reveal requests a view reattach")
    @MainActor
    func dockTerminalRevealRequestsViewReattach() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.tabs.first)
        let store = workspace.dockSplit
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let panelId = try #require(store.newSurface(kind: .terminal, inPane: rootPane, focus: true))
        let tabId = try #require(store.surfaceId(forPanelId: panelId))
        let panel = try #require(store.panel(for: tabId) as? TerminalPanel)

        store.setVisibleInUI(false)
        #expect(!panel.hostedView.debugPortalVisibleInUI)
        let reattachTokenBefore = panel.viewReattachToken

        store.setVisibleInUI(true)

        #expect(panel.hostedView.debugPortalVisibleInUI)
        #expect(panel.viewReattachToken == reattachTokenBefore + 1)
    }
}
