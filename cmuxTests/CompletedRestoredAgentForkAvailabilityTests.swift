import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CompletedRestoredAgentForkAvailabilityTests {
    @Test
    func completedRestoredAgentCannotDriveForkActions() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let snapshot = forkableClaudeSnapshot()
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = snapshot
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .observedAgentCommandRunning

        #expect(workspace.forkAgentConversationContextMenuAvailability(forPanelId: panel.id) == .available)
        #expect(workspace.forkAgentConversationContextMenuOpenSelection(forPanelId: panel.id).snapshot != nil)

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panel.id] != nil)
        #expect(workspace.forkAgentConversationContextMenuAvailability(forPanelId: panel.id) == .noAgentSnapshot)
        #expect(workspace.forkAgentConversationContextMenuOpenSelection(forPanelId: panel.id).snapshot == nil)
        let didForkFromCompletedAgent = await workspace.forkAgentConversationFromContextMenu(
            fromPanelId: panel.id,
            destination: .newTab
        )
        #expect(!didForkFromCompletedAgent)

        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: workspace.id,
            panelId: panel.id
        )
        #expect(
            !ContentView.commandPalettePanelHasForkableAgent(
                workspaceId: workspace.id,
                panelId: panel.id,
                supportedPanelKeys: [panelKey],
                fallbackSnapshot: workspace.restoredAgentSnapshotForContinuation(panelId: panel.id),
                allowsAgentContinuation: workspace.allowsAgentContinuation(forPanelId: panel.id)
            )
        )
        #expect(
            ContentView.commandPaletteImmediateForkExecutionSnapshot(
                workspaceId: workspace.id,
                panelId: panel.id,
                isRemoteTerminal: false,
                supportedPanelKeys: [panelKey],
                supportedRemoteContextsByPanelKey: [panelKey: false],
                snapshotFingerprintsByPanelKey: [
                    panelKey: ContentView.commandPaletteForkSnapshotFingerprint(snapshot),
                ],
                fallbackSnapshot: workspace.restoredAgentSnapshotForContinuation(panelId: panel.id),
                cachedSnapshot: snapshot,
                allowsAgentContinuation: workspace.allowsAgentContinuation(forPanelId: panel.id)
            ) == nil
        )
    }

    private func forkableClaudeSnapshot() -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "completed-agent-fork-availability",
            workingDirectory: "/tmp/completed-agent-fork-availability",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", "completed-agent-fork-availability"],
                workingDirectory: "/tmp/completed-agent-fork-availability",
                capturedAt: 1_777_777_777,
                source: "test"
            )
        )
    }
}
