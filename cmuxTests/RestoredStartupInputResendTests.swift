import CmuxWorkspaces
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ghostty types a restored agent's `cmux restore` selector as soon as the PTY
/// exists. A slow login shell can discard that typeahead while it initializes,
/// leaving the pane at an empty prompt (https://github.com/manaflow-ai/cmux/issues/5473).
/// The lifecycle coordinator retains the input so the owner can replay it once.
@MainActor
@Suite("Restored startup input resend")
struct RestoredStartupInputResendTests {
    private let selector = " cmux restore antigravity 6e8458c7-7970-41e0-8d3e-00beda48097b\n"

    private func awaitingCoordinator(panelId: UUID) -> RestoredAgentLifecycleCoordinator {
        let coordinator = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        coordinator.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        coordinator.registerStartupInput(selector, panelId: panelId)
        return coordinator
    }

    @Test("Replays the retained input once while the launch is still waiting at an idle prompt")
    func replaysOnceWhilePromptStaysIdle() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)

        #expect(coordinator.awaitsStartupInput(panelId: panelId))
        #expect(coordinator.armStartupInputResend(panelId: panelId))
        // A second idle-prompt report must not arm a second timer.
        #expect(!coordinator.armStartupInputResend(panelId: panelId))

        #expect(
            coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == selector
        )
        // Only one replay is ever handed out.
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("A prompt-then-command sequence that reached the command phase is not replayed")
    func doesNotReplayOnceTheCommandStarted() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))

        // Shell integration reported the command running before the grace period elapsed.
        coordinator.setResumeState(.autoResumeCommandRunning, panelId: panelId)
        coordinator.clearStartupInput(panelId: panelId)

        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("A shell that is no longer idle when the grace period ends is left alone")
    func doesNotReplayIntoARunningCommand() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        #expect(coordinator.armStartupInputResend(panelId: panelId))

        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .commandRunning) == nil)
        // The input stays retained for a later idle prompt.
        #expect(coordinator.awaitsStartupInput(panelId: panelId))
    }

    @Test("Manual and unrestored launches never arm a replay")
    func onlyAwaitingLaunchesArm() {
        let panelId = UUID()
        let coordinator = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        coordinator.registerStartupInput(selector, panelId: panelId)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
        #expect(!coordinator.armStartupInputResend(panelId: panelId))

        coordinator.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: nil
        )
        #expect(!coordinator.armStartupInputResend(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
    }

    @Test("A Workspace/Dock transfer carries the retained input only while the launch still awaits it")
    func transferCarriesInputWhileAwaiting() {
        let panelId = UUID()
        let source = awaitingCoordinator(panelId: panelId)
        let destination = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })

        destination.seedTransferredState(
            panelId: panelId,
            snapshot: nil,
            resumeState: .awaitingAutoResumeCommand,
            completedGeneration: nil,
            resumeWorkingDirectory: nil,
            startupInput: source.startupInput(panelId: panelId)
        )
        #expect(destination.awaitsStartupInput(panelId: panelId))
        #expect(destination.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == selector)

        // Once the command ran before the move, nothing may be replayed after it.
        let settled = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        settled.seedTransferredState(
            panelId: panelId,
            snapshot: nil,
            resumeState: .autoResumeCommandRunning,
            completedGeneration: nil,
            resumeWorkingDirectory: nil,
            startupInput: selector
        )
        #expect(!settled.awaitsStartupInput(panelId: panelId))
        #expect(settled.startupInput(panelId: panelId) == nil)
    }

    @Test("Tearing down the restore forgets the retained input")
    func clearSessionRestoreForgetsInput() {
        let panelId = UUID()
        let coordinator = awaitingCoordinator(panelId: panelId)
        coordinator.clearSessionRestore(panelId: panelId)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
        #expect(coordinator.takeStartupInputForResend(panelId: panelId, shellState: .promptIdle) == nil)
    }

    @Test("A workspace replays the lost selector after its shell settles at an idle prompt")
    func workspaceReplaysAfterIdlePrompt() async throws {
        let previousGrace = Workspace.restoredStartupInputResendGrace
        Workspace.restoredStartupInputResendGrace = 0.05
        defer { Workspace.restoredStartupInputResendGrace = previousGrace }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.restoredAgentLifecycle.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        workspace.restoredAgentLifecycle.registerStartupInput(selector, panelId: panelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)
        // The grace period keeps a prompt-then-command sequence from double-typing.
        #expect(workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))

        let deadline = ContinuousClock.now + .seconds(5)
        while workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test("A workspace whose shell ran the typed selector keeps nothing to replay")
    func workspaceClearsInputOnceCommandRuns() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        workspace.restoredAgentLifecycle.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: false,
            willRunStartupCommand: false,
            willRunStartupInput: true,
            resumeWorkingDirectory: nil
        )
        workspace.restoredAgentLifecycle.registerStartupInput(selector, panelId: panelId)

        workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .autoResumeCommandRunning)
        #expect(!workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(!workspace.restoredAgentLifecycle.armStartupInputResend(panelId: panelId))
    }

    // MARK: - Workspace/Dock transfers

    /// A transfer for a launch whose typed selector is still outstanding. The
    /// default shell state models the case that matters: the shell settled at
    /// an idle prompt before the move, so the destination never sees that
    /// transition itself.
    private func awaitingTransfer(
        panel: any Panel,
        sourceWorkspaceId: UUID,
        shellActivityState: PanelShellActivityState? = .promptIdle
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
            directory: nil,
            directoryIsTrustedRemoteReport: false,
            directoryDisplayLabel: nil,
            ttyName: nil,
            cachedTitle: nil,
            customTitle: nil,
            customTitleSource: nil,
            manuallyUnread: false,
            restoredUnreadIndicator: nil,
            restorableAgent: nil,
            restorableAgentResumeState: .awaitingAutoResumeCommand,
            restoredAgentCompletedGeneration: nil,
            shellActivityState: shellActivityState,
            restoredResumeSessionWorkingDirectory: nil,
            restoredStartupInput: selector,
            resumeBinding: nil,
            managedAgentResumeBinding: nil,
            agentRuntime: nil,
            isRemoteTerminal: false,
            remoteRelayPort: nil,
            remotePTYSessionID: nil,
            remoteCleanupConfiguration: nil
        )
    }

    private func waitForReplay(
        _ coordinator: RestoredAgentLifecycleCoordinator,
        panelId: UUID
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while coordinator.awaitsStartupInput(panelId: panelId),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Re-stamping a transfer's remote cleanup configuration keeps the retained selector")
    func remoteCleanupCopyKeepsStartupInput() {
        let panel = RestoredStartupInputTransferTestPanel()
        let transfer = awaitingTransfer(panel: panel, sourceWorkspaceId: UUID())

        let copied = transfer.withRemoteCleanupConfiguration(nil)

        #expect(copied.restoredStartupInput == selector)
        #expect(copied.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(copied.shellActivityState == .promptIdle)
    }

    @Test("A workspace that adopts a pane whose shell already idled replays the selector itself")
    func workspaceReplaysAfterAdoptingIdleTransfer() async throws {
        let previousGrace = Workspace.restoredStartupInputResendGrace
        Workspace.restoredStartupInputResendGrace = 0.05
        defer { Workspace.restoredStartupInputResendGrace = previousGrace }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])

        workspace.seedDetachedRestoredAgentState(
            from: awaitingTransfer(panel: panel, sourceWorkspaceId: UUID())
        )

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
        #expect(workspace.panelShellActivityStates[panelId] == .promptIdle)
        #expect(workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        // The idle prompt was reported to the previous owner and never repeats
        // here, so adoption itself must have armed the replay.
        #expect(!workspace.restoredAgentLifecycle.armStartupInputResend(panelId: panelId))

        try await waitForReplay(workspace.restoredAgentLifecycle, panelId: panelId)
        #expect(!workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test("A Dock that adopts a pane whose shell already idled replays the selector itself")
    func dockReplaysAfterAdoptingIdleTransfer() async throws {
        let previousGrace = Workspace.restoredStartupInputResendGrace
        Workspace.restoredStartupInputResendGrace = 0.05
        defer { Workspace.restoredStartupInputResendGrace = previousGrace }

        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)

        let attached = store.attachDetachedSurface(
            awaitingTransfer(panel: panel, sourceWorkspaceId: sourceWorkspaceId),
            inPane: rootPane,
            focus: false
        )

        #expect(attached == panel.id)
        #expect(panel.shellActivity.state == .promptIdle)
        #expect(store.restoredAgentLifecycle.awaitsStartupInput(panelId: panel.id))
        #expect(!store.restoredAgentLifecycle.armStartupInputResend(panelId: panel.id))

        try await waitForReplay(store.restoredAgentLifecycle, panelId: panel.id)
        #expect(!store.restoredAgentLifecycle.awaitsStartupInput(panelId: panel.id))
        #expect(store.restoredAgentLifecycle.resumeStatesByPanelId[panel.id] == .awaitingAutoResumeCommand)
    }

    @Test("Detaching from a Dock carries the retained selector to the next owner")
    func dockDetachCarriesStartupInput() throws {
        let sourceWorkspaceId = UUID()
        let panel = TerminalPanel(workspaceId: sourceWorkspaceId)
        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        defer { store.closeAllPanels() }
        let rootPane = try #require(store.bonsplitController.allPaneIds.first)
        _ = store.attachDetachedSurface(
            awaitingTransfer(
                panel: panel,
                sourceWorkspaceId: sourceWorkspaceId,
                shellActivityState: nil
            ),
            inPane: rootPane,
            focus: false
        )
        #expect(store.restoredAgentLifecycle.awaitsStartupInput(panelId: panel.id))

        let detached = try #require(store.detachSurface(panelId: panel.id))
        defer { panel.close() }

        #expect(detached.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(detached.restoredStartupInput == selector)
    }
}

@MainActor
private final class RestoredStartupInputTransferTestPanel: Panel {
    let objectWillChange = ObservableObjectPublisher()
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    var displayTitle = "Restored"
    let displayIcon: String? = "terminal.fill"
    let isDirty = false

    func close() {}
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}
}
