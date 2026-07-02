import AppKit
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class DockTransferTestPanel: Panel {
    let objectWillChange = ObservableObjectPublisher()
    let id: UUID
    let panelType: PanelType
    var displayTitle: String
    let displayIcon: String?
    let isDirty = false

    init(
        id: UUID = UUID(),
        panelType: PanelType = .terminal,
        displayTitle: String = "Detached",
        displayIcon: String? = "terminal.fill"
    ) {
        self.id = id
        self.panelType = panelType
        self.displayTitle = displayTitle
        self.displayIcon = displayIcon
    }

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}

extension DockSocketLifecycleTests {
    @MainActor
    private func detachedTerminalTransfer(
        panel: any Panel,
        sourceWorkspaceId: UUID,
        directory: String? = nil,
        cachedTitle: String? = nil,
        restorableAgent: SessionRestorableAgentSnapshot? = nil,
        restorableAgentResumeState: Workspace.RestoredAgentResumeState? = nil,
        restoredResumeSessionWorkingDirectory: String? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        agentRuntime: Workspace.DetachedAgentRuntimeState? = nil
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
            directory: directory,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: cachedTitle,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: restorableAgent,
            restorableAgentResumeState: restorableAgentResumeState,
            restoredResumeSessionWorkingDirectory: restoredResumeSessionWorkingDirectory,
            resumeBinding: resumeBinding,
            agentRuntime: agentRuntime,
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

    @Test("Dock transfer drops transient resumed-agent cwd rescue state")
    @MainActor
    func dockTransferDropsTransientResumedAgentCwdRescueState() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "claude-dock-transfer-\(UUID().uuidString)"
        let sessionDirectory = "/tmp/cmux-dock-transfer-session"
        let trackedDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: sessionDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", sessionId],
                workingDirectory: sessionDirectory,
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "Claude",
            kind: "claude",
            command: "{ cd -- '\(sessionDirectory)' 2>/dev/null || [ ! -d '\(sessionDirectory)' ]; } && 'claude' '--resume' '\(sessionId)'",
            cwd: sessionDirectory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_777
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            directory: trackedDirectory,
            cachedTitle: "Stale Dock Title",
            restorableAgent: agent,
            restorableAgentResumeState: .autoResumeCommandRunning,
            restoredResumeSessionWorkingDirectory: sessionDirectory,
            resumeBinding: binding
        )

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)
        #expect(attachedPanelId == panel.id)
        panel.displayTitle = "Current Dock Title"

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.panelId == panel.id)
        #expect(roundTripped.cachedTitle == "Current Dock Title")
        #expect(roundTripped.directory == trackedDirectory)
        #expect(roundTripped.restorableAgent?.sessionId == sessionId)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding?.checkpointId == sessionId)
    }

    @Test("Dock detach drops agent metadata whose recorded processes all exited")
    @MainActor
    func dockDetachDropsAgentMetadataWhoseRecordedProcessesAllExited() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "claude-dock-dead-agent-\(UUID().uuidString)"
        let sessionDirectory = "/tmp/cmux-dock-dead-agent-session"
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: sessionDirectory,
            launchCommand: nil
        )

        // A process that has provably exited by the time the pane detaches.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let deadPid = pid_t(exited.processIdentifier)
        try #require(kill(deadPid, 0) != 0)

        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            directory: sessionDirectory,
            restorableAgent: agent,
            agentRuntime: Workspace.DetachedAgentRuntimeState(
                panelId: panel.id,
                statusEntries: [:],
                agentPIDs: ["claude": deadPid],
                agentPIDKeys: ["claude"]
            )
        )

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)
        #expect(attachedPanelId == panel.id)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.directory == sessionDirectory)
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
        #expect(roundTripped.agentRuntime == nil)
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
