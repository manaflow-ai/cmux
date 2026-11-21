import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An account switch replaces the pane's shell, so a pane with no Claude
/// session must be refused before anything is respawned. The resume command
/// then waits for the respawned shell's own prompt report, and a pane that is
/// replaced or never reaches a prompt gets no resume input.
@MainActor
@Suite(.serialized)
struct WorkspaceClaudeAccountSwitchTests {
    @Test
    func paneWithoutClaudeIsRefusedAndKeepsItsShell() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let originalPanel = try #require(workspace.terminalPanel(for: panelId))

        let result = await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: "work",
            trigger: .manual,
            stopsRunningResponse: false
        )

        #expect(result == .notClaude)
        #expect(workspace.terminalPanel(for: panelId) === originalPanel)
        #expect(workspace.currentClaudeAccount(panelId: panelId) == nil)
    }

    /// Claude can start a response while the switch scans for owners and copies the transcript,
    /// after its caller looked. The last check before the restart catches it unless the caller
    /// agreed to stop a response (the socket's `force`, the menu's confirmation); an idle pane
    /// passes either way.
    @Test
    func theLastCheckBeforeTheRestartStopsOnlyAnAgreedResponse() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        #expect(!workspace.claudeAccountSwitchWouldStopUnapprovedResponse(panelId: panelId, stopsRunningResponse: false))

        workspace.setAgentLifecycle(key: Workspace.claudeAgentLifecycleKey, panelId: panelId, lifecycle: .running)

        #expect(workspace.claudeAccountSwitchWouldStopUnapprovedResponse(panelId: panelId, stopsRunningResponse: false))
        #expect(!workspace.claudeAccountSwitchWouldStopUnapprovedResponse(panelId: panelId, stopsRunningResponse: true))
    }

    /// The deadline runs on a manual clock that is never advanced, so only the report can end
    /// this wait; a report that failed to wake it would hang into the time limit.
    @Test(.timeLimit(.minutes(1)))
    func resumeWaitEndsWhenTheShellReportsItsPrompt() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let clock = CloudReadManualClock()

        let wait = Task { @MainActor in
            await workspace.waitForClaudeAccountSwitchShellPrompt(
                panelId: panelId,
                panel: panel,
                timeout: .seconds(30),
                clock: clock
            )
        }
        // The deadline sleeps once the wait has armed its observation and suspended.
        try await waitUntil { clock.pendingSleeperCount == 1 }
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        #expect(await wait.value == .prompt)
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeWaitTimesOutWhileTheShellHasNotReportedAPrompt() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let clock = CloudReadManualClock()
        // A blank panel's own model starts at an optimistic `.promptIdle`; only the
        // shell's report may release the input (#5473).

        let wait = Task { @MainActor in
            await workspace.waitForClaudeAccountSwitchShellPrompt(
                panelId: panelId,
                panel: panel,
                timeout: .seconds(15),
                clock: clock
            )
        }
        try await waitUntil { clock.pendingSleeperCount == 1 }
        clock.advance(by: .seconds(15))

        #expect(await wait.value == .timedOut)
    }

    /// As with the prompt report, the deadline never fires, so the respawn alone ends the wait.
    @Test(.timeLimit(.minutes(1)))
    func resumeWaitStopsAsSoonAsThePaneIsRespawnedAgain() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let clock = CloudReadManualClock()

        let wait = Task { @MainActor in
            await workspace.waitForClaudeAccountSwitchShellPrompt(
                panelId: panelId,
                panel: panel,
                timeout: .seconds(30),
                clock: clock
            )
        }
        try await waitUntil { clock.pendingSleeperCount == 1 }
        let replacement = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        #expect(replacement !== panel)
        #expect(await wait.value == .replaced)
    }

    /// A manual switch types its resume only into an untouched shell line too: input that
    /// reached the restarted shell before its prompt sits on that line, and the resume command
    /// would be appended to it and run with the user's words as arguments.
    @Test
    func aManualResumeIsNotTypedOnceInputReachedTheRestartedShell() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))
        panel.recordExplicitInput()
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        // Called as the manual switch calls it.
        let delivery = await workspace.deliverClaudeAccountSwitchResumeInput(
            "claude --resume a22293b7-bcef-4707-8439-2f538c8517a4\r",
            to: panel,
            panelId: panelId
        )

        #expect(delivery == .notTyped)
#if DEBUG
        #expect(panel.surface.debugPendingSocketInputForTesting().items == 0)
#endif
    }

    /// Polls a real condition; the deadline bounds only the failure path.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "the prompt wait never started its deadline")
    }
}
