import CmuxWorkspaces
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A slow login shell can discard startup typeahead while it initializes
/// (https://github.com/manaflow-ai/cmux/issues/5473). The terminal now delivers
/// the selector once after its first prompt; the lifecycle coordinator retains
/// the input only as restore ownership that survives Workspace/Dock transfers.
@MainActor
@Suite("Restored startup input ownership")
struct RestoredStartupInputOwnershipTests {
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

    @Test("Manual and unrestored launches never own startup input")
    func onlyAwaitingLaunchesOwnStartupInput() {
        let panelId = UUID()
        let coordinator = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        coordinator.registerStartupInput(selector, panelId: panelId)
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))

        coordinator.seedSessionRestore(
            panelId: panelId,
            snapshot: nil,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: nil
        )
        #expect(!coordinator.awaitsStartupInput(panelId: panelId))
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
        #expect(destination.startupInput(panelId: panelId) == selector)

        // Once the command ran before the move, the destination owns no input.
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
        #expect(coordinator.startupInput(panelId: panelId) == nil)
    }

    @Test("A prompt retains restore ownership until command acknowledgement")
    func workspaceIdlePromptRetainsRestoreOwnership() async throws {
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
        // Readiness alone cannot acknowledge execution. The binding remains
        // owned until a command-start or matching agent observation arrives.
        #expect(workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test("A workspace whose shell ran the typed selector releases startup input ownership")
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
        #expect(workspace.restoredAgentLifecycle.startupInput(panelId: panelId) == nil)
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

    @Test("Re-stamping a transfer's remote cleanup configuration keeps the retained selector")
    func remoteCleanupCopyKeepsStartupInput() {
        let panel = RestoredStartupInputTransferTestPanel()
        let transfer = awaitingTransfer(panel: panel, sourceWorkspaceId: UUID())

        let copied = transfer.withRemoteCleanupConfiguration(nil)

        #expect(copied.restoredStartupInput == selector)
        #expect(copied.restorableAgentResumeState == .awaitingAutoResumeCommand)
        #expect(copied.shellActivityState == .promptIdle)
    }

    @Test("A workspace transfer retains unacknowledged restore ownership")
    func workspaceIdleTransferRetainsRestoreOwnership() async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])

        workspace.seedDetachedRestoredAgentState(
            from: awaitingTransfer(panel: panel, sourceWorkspaceId: UUID())
        )

        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
        #expect(workspace.panelShellActivityStates[panelId] == .promptIdle)
        // A transfer retains the unacknowledged identity; no replay is scheduled.
        #expect(workspace.restoredAgentLifecycle.awaitsStartupInput(panelId: panelId))
        #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
    }

    @Test("A Dock transfer retains unacknowledged restore ownership")
    func dockIdleTransferRetainsRestoreOwnership() async throws {
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
