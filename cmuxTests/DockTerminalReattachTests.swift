import AppKit
import CmuxWorkspaces
import Combine
import Darwin
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
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
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
        customTitle: String? = nil,
        customTitleSource: Workspace.CustomTitleSource? = nil,
        restorableAgent: SessionRestorableAgentSnapshot? = nil,
        restorableAgentResumeState: Workspace.RestoredAgentResumeState? = nil,
        restoredAgentCompletedGeneration: RestoredAgentCompletedGeneration? = nil,
        shellActivityState: PanelShellActivityState? = nil,
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
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: cachedTitle,
            customTitle: customTitle,
            customTitleSource: customTitleSource,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: restorableAgent,
            restorableAgentResumeState: restorableAgentResumeState,
            restoredAgentCompletedGeneration: restoredAgentCompletedGeneration,
            shellActivityState: shellActivityState,
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

        // focusPanel applies the Dock selection once directly and once per
        // bonsplit delegate callback (didFocusPane, didSelectTab), and each
        // pass sees the still-detached portal, so the token can advance more
        // than once. The behavioral guarantee is that focusing requested a
        // reattach at all.
        #expect(panel.viewReattachToken > reattachTokenBefore)
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

        // See visibleDetachedDockTerminalRequestsViewReattach: focusPanel can
        // request a reattach once per selection pass against a stale anchor,
        // so assert the reattach happened rather than an exact count.
        #expect(panel.viewReattachToken > reattachTokenBefore)
    }

    @Test("Dock transfer keeps resumed-agent cwd rescue state while not proven dead")
    @MainActor
    func dockTransferKeepsResumedAgentCwdRescueStateWhileNotProvenDead() throws {
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
            customTitle: "Pinned Agent",
            customTitleSource: .user,
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
        #expect(roundTripped.title == "Pinned Agent")
        #expect(roundTripped.cachedTitle == "Current Dock Title")
        #expect(roundTripped.customTitle == "Pinned Agent")
        #expect(roundTripped.directory == trackedDirectory)
        #expect(roundTripped.restorableAgent?.sessionId == sessionId)
        #expect(roundTripped.restorableAgentResumeState == .autoResumeCommandRunning)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == sessionDirectory)
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
            restorableAgentResumeState: .autoResumeCommandRunning,
            restoredResumeSessionWorkingDirectory: sessionDirectory,
            agentRuntime: Workspace.DetachedAgentRuntimeState(
                panelId: panel.id,
                statusEntries: [:],
                agentPIDs: ["claude": deadPid],
                agentPIDProcessIdentities: [:],
                agentPIDKeys: ["claude"]
            )
        )

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)
        #expect(attachedPanelId == panel.id)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.directory == sessionDirectory)
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
        #expect(roundTripped.agentRuntime == nil)
    }

    @Test("Dock detach drops agent metadata when a live pid is a reused identity")
    @MainActor
    func dockDetachDropsAgentMetadataWhenLivePidIsReusedIdentity() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "claude-dock-reused-pid-\(UUID().uuidString)"
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: "/tmp/cmux-dock-reused-pid-session",
            launchCommand: nil
        )

        // The test host's own pid is alive (`kill` succeeds), but its recorded
        // start-time identity deliberately mismatches — the shape of a pid
        // that was reused by an unrelated process after the agent exited.
        let livePid = getpid()
        try #require(kill(livePid, 0) == 0)
        let currentIdentity = try #require(Workspace.agentPIDProcessIdentity(pid: livePid))
        let mismatchedIdentity = AgentPIDProcessIdentity(
            pid: livePid,
            startSeconds: currentIdentity.startSeconds &- 1,
            startMicroseconds: currentIdentity.startMicroseconds
        )

        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .autoResumeCommandRunning,
            agentRuntime: Workspace.DetachedAgentRuntimeState(
                panelId: panel.id,
                statusEntries: [:],
                agentPIDs: ["claude": livePid],
                agentPIDProcessIdentities: ["claude": mismatchedIdentity],
                agentPIDKeys: ["claude"]
            )
        )

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)
        #expect(attachedPanelId == panel.id)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.agentRuntime == nil)
    }

    @Test("Dock detach keeps agent metadata while the recorded identity still runs")
    @MainActor
    func dockDetachKeepsAgentMetadataWhileRecordedIdentityStillRuns() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "claude-dock-live-agent-\(UUID().uuidString)"
        let agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: "/tmp/cmux-dock-live-agent-session",
            launchCommand: nil
        )

        let livePid = getpid()
        let currentIdentity = try #require(Workspace.agentPIDProcessIdentity(pid: livePid))

        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .autoResumeCommandRunning,
            agentRuntime: Workspace.DetachedAgentRuntimeState(
                panelId: panel.id,
                statusEntries: [:],
                agentPIDs: ["claude": livePid],
                agentPIDProcessIdentities: ["claude": currentIdentity],
                agentPIDKeys: ["claude"]
            )
        )

        let attachedPanelId = store.attachDetachedSurface(detached, inPane: rootPane, focus: false)
        #expect(attachedPanelId == panel.id)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent?.sessionId == sessionId)
        #expect(roundTripped.restorableAgentResumeState == .autoResumeCommandRunning)
        #expect(roundTripped.agentRuntime != nil)
    }

    @Test("Dock process probe treats only ESRCH as exited")
    @MainActor
    func dockProcessProbeTreatsOnlyESRCHAsExited() {
        #expect(DockSplitStore.dockAgentPIDProbeIndicatesExited(result: 0, errnoCode: 0) == false)
        #expect(DockSplitStore.dockAgentPIDProbeIndicatesExited(result: -1, errnoCode: EPERM) == false)
        #expect(DockSplitStore.dockAgentPIDProbeIndicatesExited(result: -1, errnoCode: ESRCH))
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
