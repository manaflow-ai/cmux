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
        directoryIsTrustedRemoteReport: Bool = false,
        restorableAgent: SessionRestorableAgentSnapshot? = nil,
        restorableAgentResumeState: Workspace.RestoredAgentResumeState? = nil,
        restoredAgentCompletedGeneration: RestoredAgentCompletedGeneration? = nil,
        shellActivityState: PanelShellActivityState? = nil,
        restoredResumeSessionWorkingDirectory: String? = nil,
        resumeBinding: SurfaceResumeBindingSnapshot? = nil,
        managedAgentResumeBinding: SurfaceResumeBindingSnapshot? = nil,
        agentRuntime: Workspace.DetachedAgentRuntimeState? = nil,
        isRemoteTerminal: Bool = false
    ) -> Workspace.DetachedSurfaceTransfer {
        Workspace.DetachedSurfaceTransfer(
            sourceWorkspaceId: sourceWorkspaceId,
            sessionRestoreSourceWorkspaceId: nil,
            panelId: panel.id,
            panel: panel,
            title: panel.displayTitle,
            icon: panel.displayIcon,
            iconImageData: nil,
            kind: "terminal",
            isLoading: false,
            isPinned: false,
            directory: directory,
            directoryIsTrustedRemoteReport: directoryIsTrustedRemoteReport,
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
            recoveryNeededWorkingDirectory: nil,
            resumeBinding: resumeBinding,
            managedAgentResumeBinding: managedAgentResumeBinding,
            agentRuntime: agentRuntime,
            isRemoteTerminal: isRemoteTerminal,
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
        let store = workspace.requiredDockSplitForTesting
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
        let store = workspace.requiredDockSplitForTesting
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
        let attachedTabId = try #require(
            store.surfaceId(forPanelId: panel.id)
        )
        #expect(
            store.bonsplitController.tab(attachedTabId)?
                .hasCustomTitle == true
        )
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

    @Test("Clearing a transferred Dock title does not resurrect stale metadata")
    @MainActor
    func clearingTransferredDockTitleStaysCleared() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        panel.displayTitle = "Current Dock Title"
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(
            store.bonsplitController.allPaneIds.first
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            cachedTitle: "Stale Dock Title",
            customTitle: "Pinned Agent",
            customTitleSource: .user
        )

        _ = try #require(
            store.attachDetachedSurface(
                detached,
                inPane: rootPane,
                focus: false
            )
        )
        #expect(
            store.setDockPanelCustomTitle(
                panelId: panel.id,
                title: nil
            )
        )
        let snapshot = try #require(
            store.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.id == panel.id }
        )
        #expect(snapshot.customTitle == nil)
        #expect(snapshot.title == panel.displayTitle)

        let roundTripped = try #require(
            store.detachSurface(panelId: panel.id)
        )
        #expect(roundTripped.customTitle == nil)
        #expect(roundTripped.title == panel.displayTitle)
        roundTripped.panel.close()
    }

    @Test("Dock shell preexec retains a manual agent restore binding")
    @MainActor
    func dockShellPreexecRetainsManualAgentRestoreBinding() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "grok-dock-manual-\(UUID().uuidString)"
        let directory = "/tmp/cmux-grok-dock-manual"
        let agent = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "Grok",
            kind: "grok",
            command: "grok -r \(sessionId)",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .manualResumeAvailable,
            shellActivityState: .promptIdle,
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        store.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)

        #expect(store.restoredAgentLifecycle.snapshotsByPanelId[panel.id] == nil)
        let retainedBinding = try #require(store.surfaceResumeBinding(panelId: panel.id))
        #expect(retainedBinding.checkpointId == sessionId)
        #expect(retainedBinding.autoResume == false)
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))
        #expect(store.surfaceResumeBinding(panelId: panel.id) == nil)
    }

    @Test("Dock completion for an older restored session preserves a replacement binding")
    @MainActor
    func dockOlderRestoredSessionCompletionPreservesReplacementBinding() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let restoredSessionId = "grok-dock-restored-\(UUID().uuidString)"
        let replacementSessionId = "grok-dock-replacement-\(UUID().uuidString)"
        let restoredAgent = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: restoredSessionId,
            workingDirectory: "/tmp/cmux-grok-dock-restored",
            launchCommand: nil
        )
        let restoredBinding = SurfaceResumeBindingSnapshot(
            name: "Grok",
            kind: "grok",
            command: "grok -r \(restoredSessionId)",
            checkpointId: restoredSessionId,
            source: "agent-hook",
            autoResume: true
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: restoredAgent,
            restorableAgentResumeState: .autoResumeCommandRunning,
            shellActivityState: .commandRunning,
            resumeBinding: restoredBinding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let replacementBinding = SurfaceResumeBindingSnapshot(
            name: "Grok",
            kind: "grok",
            command: "grok -r \(replacementSessionId)",
            checkpointId: replacementSessionId,
            source: "agent-hook",
            autoResume: true
        )
        store.surfaceResumeBindingsByPanelId[panel.id] = replacementBinding
        store.managedAgentResumeBindingsByPanelId[panel.id] = replacementBinding

        store.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)

        let retainedBinding = try #require(store.surfaceResumeBinding(panelId: panel.id))
        #expect(retainedBinding.checkpointId == replacementSessionId)
        #expect(retainedBinding.autoResume == true)
    }

    @Test("Dock transfer drops a restored snapshot superseded by a live hook session")
    @MainActor
    func dockTransferDropsRestoredSnapshotSupersededByLiveHookSession() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let staleSessionId = "omp-dock-stale-\(UUID().uuidString)"
        let currentSessionId = "omp-dock-current-\(UUID().uuidString)"
        let staleAgent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: staleSessionId,
            workingDirectory: "/tmp/cmux-omp-stale",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "omp",
                executablePath: "/usr/local/bin/omp",
                arguments: ["/usr/local/bin/omp", "--resume", staleSessionId],
                workingDirectory: "/tmp/cmux-omp-stale",
                capturedAt: 1_777_777_777,
                source: "process"
            )
        )
        let staleBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(staleSessionId)'",
            cwd: "/tmp/cmux-omp-stale",
            checkpointId: staleSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_777
        )
        let completedGeneration = RestoredAgentCompletedGeneration(
            completedAt: 1_777_777_777,
            processIdentities: []
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: staleAgent,
            restorableAgentResumeState: .completedAgentExit,
            restoredAgentCompletedGeneration: completedGeneration,
            restoredResumeSessionWorkingDirectory: "/tmp/cmux-omp-stale",
            resumeBinding: staleBinding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        store.surfaceResumeBindingsByPanelId[panel.id] = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(currentSessionId)'",
            cwd: "/tmp/cmux-omp-current",
            checkpointId: currentSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        store.recordAgentPID(
            key: "omp.\(currentSessionId)",
            pid: getpid(),
            panelId: panel.id
        )
        store.setAgentLifecycle(key: "omp", panelId: panel.id, lifecycle: .running)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.resumeBinding?.checkpointId == currentSessionId)
        #expect(roundTripped.agentRuntime?.agentPIDs["omp.\(currentSessionId)"] == getpid())
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredAgentCompletedGeneration == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
    }

    @Test("Replacement and clear cannot restore an older cached Dock session")
    @MainActor
    func replacementThenClearDoesNotRestoreOlderCachedDockSession() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let oldSessionId = "omp-cached-old-\(UUID().uuidString)"
        let newSessionId = "omp-current-new-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-replaced-then-cleared"
        let oldAgent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: oldSessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let oldBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(oldSessionId)'",
            cwd: directory,
            checkpointId: oldSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_777_777_777
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: oldAgent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: oldBinding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let newBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(newSessionId)'",
            cwd: directory,
            checkpointId: newSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        #expect(store.setSurfaceResumeBinding(newBinding, panelId: panel.id))
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))

        let persistedPanel = try #require(
            store.sessionSnapshot(includeScrollback: false).panels.first {
                $0.id == panel.id
            }
        )
        #expect(persistedPanel.terminal?.agent == nil)
        #expect(persistedPanel.terminal?.resumeBinding == nil)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredAgentCompletedGeneration == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
    }

    @Test("Replacement and clear cannot restore snapshot-only Dock state")
    @MainActor
    func replacementThenClearDoesNotRestoreSnapshotOnlyDockState() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let oldSessionId = "omp-snapshot-old-\(UUID().uuidString)"
        let newSessionId = "omp-binding-new-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-snapshot-replaced"
        let oldAgent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: oldSessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: oldAgent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let newBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(newSessionId)'",
            cwd: directory,
            checkpointId: newSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        #expect(store.setSurfaceResumeBinding(newBinding, panelId: panel.id))
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))

        let persistedPanel = try #require(
            store.sessionSnapshot(includeScrollback: false).panels.first {
                $0.id == panel.id
            }
        )
        #expect(persistedPanel.terminal?.agent == nil)
        #expect(persistedPanel.terminal?.resumeBinding == nil)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredAgentCompletedGeneration == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
    }

    @Test("Matching hook clear invalidates snapshot-only Dock state")
    @MainActor
    func matchingHookClearInvalidatesSnapshotOnlyDockState() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-snapshot-matching-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-snapshot-matching"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        #expect(store.setSurfaceResumeBinding(binding, panelId: panel.id))
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))

        let persistedPanel = try #require(
            store.sessionSnapshot(includeScrollback: false).panels.first {
                $0.id == panel.id
            }
        )
        #expect(persistedPanel.terminal?.agent == nil)
        #expect(persistedPanel.terminal?.resumeBinding == nil)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredAgentCompletedGeneration == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
    }

    @Test("Snapshot-only Dock state cannot retarget a replacement hook binding")
    @MainActor
    func snapshotOnlyDockStateDoesNotRetargetReplacementHookBinding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dock-snapshot-only-\(UUID().uuidString)", isDirectory: true)
        let staleDirectory = root.appendingPathComponent("stale", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            workingDirectory: currentDirectory.path,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver(
                liveDirectoryProvider: { _ in currentDirectory.path }
            )
        )
        defer {
            store.closeAllPanels()
            try? FileManager.default.removeItem(at: root)
        }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let staleSessionId = "omp-snapshot-only-stale-\(UUID().uuidString)"
        let currentSessionId = "omp-snapshot-only-current-\(UUID().uuidString)"
        let staleAgent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: staleSessionId,
            workingDirectory: staleDirectory.path,
            launchCommand: nil
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: staleAgent,
            restorableAgentResumeState: .autoResumeCommandRunning,
            restoredResumeSessionWorkingDirectory: staleDirectory.path
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        store.surfaceResumeBindingsByPanelId[panel.id] = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(currentSessionId)'",
            cwd: currentDirectory.path,
            checkpointId: currentSessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.resumeBinding?.checkpointId == currentSessionId)
        #expect(roundTripped.resumeBinding?.cwd == currentDirectory.path)
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
    }

    @Test("Registered lifecycle command reaches a panel in a global Dock")
    @MainActor
    func registeredLifecycleCommandReachesGlobalDockPanel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-dock-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "vault": {
            "agents": [
              {
                "id": "local-agent",
                "name": "Local Agent",
                "detect": { "processName": "local-agent" },
                "sessionIdSource": { "type": "argvOption", "argvOption": "--session" },
                "resumeCommand": "local-agent --session {{sessionId}}",
                "cwd": "preserve"
              }
            ]
          }
        }
        """.write(to: configDirectory.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            workingDirectory: root.path,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { root.path }
        )
        let remotePanel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            workingDirectory: root.path,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let remoteStore = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        let directorylessPanel = DockTransferTestPanel()
        let directorylessStore = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil }
        )
        defer {
            TerminalMutationBus.shared.drainForTesting()
            store.closeAllPanels()
            remoteStore.closeAllPanels()
            directorylessStore.closeAllPanels()
            try? FileManager.default.removeItem(at: root)
        }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            directory: root.path
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let response = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle local-agent idle "
                + "--tab=\(store.workspaceId.uuidString) --panel=\(panel.id.uuidString)"
        )
        #expect(response == "OK")
        TerminalMutationBus.shared.drainForTesting()
        #expect(store.agentRuntimeByPanelId[panel.id]?.agentLifecycleStates["local-agent"] == .idle)

        let remoteRootPane = try #require(
            remoteStore.bonsplitController.allPaneIds.first
        )
        let remoteTransfer = detachedTerminalTransfer(
            panel: remotePanel,
            sourceWorkspaceId: sourceWorkspaceId,
            directory: root.path,
            directoryIsTrustedRemoteReport: true,
            isRemoteTerminal: true
        )
        #expect(
            remoteStore.attachDetachedSurface(
                remoteTransfer,
                inPane: remoteRootPane,
                focus: false
            ) == remotePanel.id
        )
        let remoteResponse = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle local-agent idle "
                + "--tab=\(remoteStore.workspaceId.uuidString) "
                + "--panel=\(remotePanel.id.uuidString)"
        )
        #expect(remoteResponse.contains("Unsupported agent lifecycle key"))

        let remoteScope = ControlSidebarPanelOwner
            .dock(remoteStore)
            .agentLifecycleRegistryScope(panelId: remotePanel.id)
        let emptyHome = root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let remoteRegistry = remoteScope.loadRegistry(
            homeDirectory: emptyHome.path,
            environment: ["PWD": root.path]
        )
        #expect(remoteRegistry.registration(id: "local-agent") == nil)

        let directorylessRootPane = try #require(
            directorylessStore.bonsplitController.allPaneIds.first
        )
        let directorylessTransfer = detachedTerminalTransfer(
            panel: directorylessPanel,
            sourceWorkspaceId: sourceWorkspaceId
        )
        #expect(
            directorylessStore.attachDetachedSurface(
                directorylessTransfer,
                inPane: directorylessRootPane,
                focus: false
            ) == directorylessPanel.id
        )
        let directorylessScope = ControlSidebarPanelOwner
            .dock(directorylessStore)
            .agentLifecycleRegistryScope(panelId: directorylessPanel.id)
        let directorylessRegistry = directorylessScope.loadRegistry(
            homeDirectory: emptyHome.path,
            environment: ["PWD": root.path]
        )
        #expect(directorylessRegistry.registration(id: "local-agent") == nil)
    }

    @Test("Dock detach preserves binding-only resume state")
    @MainActor
    func dockDetachPreservesBindingOnlyResumeState() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-binding-only-\(UUID().uuidString)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: "/tmp/cmux-omp-binding-only",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgentResumeState: .awaitingAutoResumeCommand,
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(roundTripped.resumeBinding?.checkpointId == sessionId)
    }

    @Test("Binding-only tmux transfer keeps hook ownership through refresh and clear")
    @MainActor
    func bindingOnlyTmuxTransferKeepsHookOwnershipThroughRefreshAndClear() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let sourceStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { sourceStore.closeAllPanels() }
        let sourcePane = try #require(
            sourceStore.bonsplitController.allPaneIds.first
        )
        let sessionId = "omp-binding-only-tmux-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-binding-only-tmux"
        let managedBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgentResumeState: .awaitingAutoResumeCommand,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: managedBinding
        )
        #expect(
            sourceStore.attachDetachedSurface(
                detached,
                inPane: sourcePane,
                focus: false
            ) == panel.id
        )

        let tmuxBinding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t cmux",
            cwd: directory,
            checkpointId: "cmux",
            source: "process-detected",
            autoResume: true,
            updatedAt: 1_999_999_999
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: sourceWorkspaceId, panelId: panel.id): tmuxBinding,
        ])
        _ = sourceStore.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let firstTransfer = try #require(
            sourceStore.detachSurface(panelId: panel.id)
        )
        #expect(firstTransfer.resumeBinding?.source == "process-detected")
        #expect(firstTransfer.managedAgentResumeBinding?.checkpointId == sessionId)
        #expect(firstTransfer.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(firstTransfer.restoredResumeSessionWorkingDirectory == directory)

        let refreshedStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { refreshedStore.closeAllPanels() }
        let refreshedPane = try #require(
            refreshedStore.bonsplitController.allPaneIds.first
        )
        #expect(
            refreshedStore.attachDetachedSurface(
                firstTransfer,
                inPane: refreshedPane,
                focus: false
            ) == panel.id
        )
        #expect(
            refreshedStore.setSurfaceResumeBinding(
                managedBinding,
                panelId: panel.id
            )
        )
        _ = refreshedStore.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let refreshedTransfer = try #require(
            refreshedStore.detachSurface(panelId: panel.id)
        )
        #expect(refreshedTransfer.resumeBinding?.source == "process-detected")
        #expect(refreshedTransfer.managedAgentResumeBinding?.checkpointId == sessionId)
        #expect(refreshedTransfer.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(refreshedTransfer.restoredResumeSessionWorkingDirectory == directory)

        let clearedStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { clearedStore.closeAllPanels() }
        let clearedPane = try #require(
            clearedStore.bonsplitController.allPaneIds.first
        )
        #expect(
            clearedStore.attachDetachedSurface(
                refreshedTransfer,
                inPane: clearedPane,
                focus: false
            ) == panel.id
        )
        #expect(clearedStore.clearSurfaceResumeBinding(
            panelId: panel.id,
            binding: managedBinding
        ))

        let clearedTransfer = try #require(
            clearedStore.detachSurface(panelId: panel.id)
        )
        #expect(clearedTransfer.restorableAgent == nil)
        #expect(clearedTransfer.restorableAgentResumeState == nil)
        #expect(clearedTransfer.restoredAgentCompletedGeneration == nil)
        #expect(clearedTransfer.restoredResumeSessionWorkingDirectory == nil)
        #expect(clearedTransfer.resumeBinding?.source == "process-detected")
        #expect(clearedTransfer.managedAgentResumeBinding == nil)
    }

    @Test("Dock detach preserves a completed tombstone after its binding clears")
    @MainActor
    func dockDetachPreservesCompletedTombstoneAfterBindingClears() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let completedGeneration = RestoredAgentCompletedGeneration(
            completedAt: 1_888_888_888,
            processIdentities: []
        )
        let sessionId = "omp-completed-binding-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-completed-binding"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .completedAgentExit,
            restoredAgentCompletedGeneration: completedGeneration,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == .completedAgentExit)
        #expect(roundTripped.restoredAgentCompletedGeneration?.completedAt == completedGeneration.completedAt)
        #expect(roundTripped.restoredAgentCompletedGeneration?.processIdentities.isEmpty == true)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
    }

    @Test("Session-ending Dock clear marks completion before a prompt event")
    @MainActor
    func sessionEndingDockClearMarksCompletionBeforePrompt() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-ended-before-prompt-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-ended-before-prompt"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        #expect(store.clearSurfaceResumeBinding(
            panelId: panel.id,
            agentSessionEnded: true
        ))

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == .completedAgentExit)
        #expect(roundTripped.restoredAgentCompletedGeneration != nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding == nil)
    }

    @Test("Process-detected tmux binding preserves the managed Dock agent")
    @MainActor
    func processDetectedTmuxBindingPreservesManagedDockAgent() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-inside-tmux-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-inside-tmux"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        store.surfaceResumeBindingsByPanelId[panel.id] = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t cmux",
            cwd: directory,
            checkpointId: "cmux",
            source: "process-detected",
            autoResume: true,
            updatedAt: 1_999_999_999
        )

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent?.sessionId == sessionId)
        #expect(roundTripped.restorableAgentResumeState == .observedAgentCommandRunning)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == directory)
        #expect(roundTripped.resumeBinding?.source == "process-detected")
    }

    @Test("Session-ending hook clear survives a process-detected tmux binding")
    @MainActor
    func sessionEndingHookClearSurvivesProcessDetectedTmuxBinding() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: sourceWorkspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-ended-inside-tmux-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-ended-inside-tmux"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let managedBinding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .observedAgentCommandRunning,
            restoredResumeSessionWorkingDirectory: directory,
            resumeBinding: managedBinding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        #expect(store.setSurfaceResumeBinding(managedBinding, panelId: panel.id))

        let tmuxBinding = SurfaceResumeBindingSnapshot(
            name: "tmux",
            kind: "tmux",
            command: "tmux attach-session -t cmux",
            cwd: directory,
            checkpointId: "cmux",
            source: "process-detected",
            autoResume: true,
            updatedAt: 1_999_999_999
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: sourceWorkspaceId, panelId: panel.id): tmuxBinding,
        ])
        let tmuxSnapshot = store.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let persistedTerminal = try #require(
            tmuxSnapshot.panels.first { $0.id == panel.id }?.terminal
        )
        #expect(persistedTerminal.resumeBinding?.source == "process-detected")
        #expect(persistedTerminal.managedAgentResumeBinding?.checkpointId == sessionId)
        #expect(store.surfaceResumeBinding(panelId: panel.id)?.source == "process-detected")

        let transferred = try #require(store.detachSurface(panelId: panel.id))
        #expect(transferred.resumeBinding?.source == "process-detected")
        #expect(transferred.managedAgentResumeBinding?.checkpointId == sessionId)

        let destinationStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { destinationStore.closeAllPanels() }
        let destinationPane = try #require(
            destinationStore.bonsplitController.allPaneIds.first
        )
        #expect(
            destinationStore.attachDetachedSurface(
                transferred,
                inPane: destinationPane,
                focus: false
            ) == panel.id
        )
        #expect(
            destinationStore.managedAgentResumeBinding(panelId: panel.id)?
                .checkpointId == sessionId
        )
        #expect(destinationStore.clearSurfaceResumeBinding(
            panelId: panel.id,
            agentSessionEnded: true
        ))

        let roundTripped = try #require(
            destinationStore.detachSurface(panelId: panel.id)
        )
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.restorableAgentResumeState == .completedAgentExit)
        #expect(roundTripped.restoredAgentCompletedGeneration != nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
        #expect(roundTripped.resumeBinding?.source == "process-detected")
    }

    @Test("Cleared Dock binding cannot fall back to the cached transfer")
    @MainActor
    func clearedDockBindingDoesNotReturnFromCachedTransfer() throws {
        let sourceWorkspaceId = UUID()
        let panel = DockTransferTestPanel()
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil }
        )
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        let sessionId = "omp-cleared-dock-binding-\(UUID().uuidString)"
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: "/tmp/cmux-omp-cleared-binding",
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: "/tmp/cmux-omp-cleared-binding",
            launchCommand: nil
        )
        let detached = detachedTerminalTransfer(
            panel: panel,
            sourceWorkspaceId: sourceWorkspaceId,
            restorableAgent: agent,
            restorableAgentResumeState: .awaitingAutoResumeCommand,
            restoredResumeSessionWorkingDirectory: "/tmp/cmux-omp-cleared-binding",
            resumeBinding: binding
        )
        #expect(store.attachDetachedSurface(detached, inPane: rootPane, focus: false) == panel.id)
        #expect(store.clearSurfaceResumeBinding(panelId: panel.id))

        let roundTripped = try #require(store.detachSurface(panelId: panel.id))
        #expect(roundTripped.restorableAgent == nil)
        #expect(roundTripped.resumeBinding == nil)
        #expect(roundTripped.restorableAgentResumeState == nil)
        #expect(roundTripped.restoredResumeSessionWorkingDirectory == nil)
    }

    @Test("Cleared binding cannot transfer state from a session-restored Dock panel")
    @MainActor
    func clearedBindingDoesNotTransferSessionRestoredDockState() throws {
        let defaultsName = "DockTerminalReattachTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let savedPanelId = UUID()
        let sessionId = "omp-restored-binding-\(UUID().uuidString)"
        let directory = "/tmp/cmux-omp-restored-binding"
        let agent = SessionRestorableAgentSnapshot(
            kind: .custom("omp"),
            sessionId: sessionId,
            workingDirectory: directory,
            launchCommand: nil
        )
        let binding = SurfaceResumeBindingSnapshot(
            name: "OMP",
            kind: "omp",
            command: "'omp' '--resume' '\(sessionId)'",
            cwd: directory,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: 1_888_888_888
        )
        let panelSnapshot = SessionPanelSnapshot(
            id: savedPanelId,
            type: .terminal,
            title: "Restored OMP",
            customTitle: nil,
            directory: directory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                agent: agent,
                resumeBinding: binding,
                wasAgentRunning: false
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer { store.closeAllPanels() }
        let restoredIds = store.restoreSessionSnapshot(SessionSplitContainerSnapshot(
            focusedPanelId: savedPanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [savedPanelId],
                selectedPanelId: savedPanelId
            )),
            panels: [panelSnapshot]
        ))
        let panelId = try #require(restoredIds[savedPanelId])
        #expect(store.detachedSurfaceTransfersByPanelId[panelId] == nil)
        store.restoredResumeSessionWorkingDirectoriesByPanelId[panelId] = directory
        #expect(store.clearSurfaceResumeBinding(panelId: panelId))

        let detached = try #require(store.detachSurface(panelId: panelId))
        #expect(detached.restorableAgent == nil)
        #expect(detached.restorableAgentResumeState == nil)
        #expect(detached.restoredAgentCompletedGeneration == nil)
        #expect(detached.restoredResumeSessionWorkingDirectory == nil)
        #expect(detached.resumeBinding == nil)
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
        let store = workspace.requiredDockSplitForTesting
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
