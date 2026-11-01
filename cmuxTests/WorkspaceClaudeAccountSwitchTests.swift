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
            trigger: .manual
        )

        #expect(result == .notClaude)
        #expect(workspace.terminalPanel(for: panelId) === originalPanel)
        #expect(workspace.currentClaudeAccount(panelId: panelId) == nil)
    }

    @Test
    func resumeWaitEndsWhenTheShellReportsItsPrompt() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let clock = ContinuousClock()
        let start = clock.now

        let wait = Task { @MainActor in
            await workspace.waitForClaudeAccountSwitchShellPrompt(
                panelId: panelId,
                panel: panel,
                timeout: .seconds(30)
            )
        }
        // Lets the wait arm its observation before the report arrives.
        await Task.yield()
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        #expect(await wait.value == .prompt)
        // The report, not the 30 s deadline, ended the wait.
        #expect(clock.now - start < .seconds(10))
    }

    @Test
    func resumeWaitTimesOutWhileTheShellHasNotReportedAPrompt() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        // A blank panel's own model starts at an optimistic `.promptIdle`; only the
        // shell's report may release the input (#5473).

        let readiness = await workspace.waitForClaudeAccountSwitchShellPrompt(
            panelId: panelId,
            panel: panel,
            timeout: .milliseconds(50)
        )

        #expect(readiness == .timedOut)
    }

    @Test
    func resumeWaitStopsAsSoonAsThePaneIsRespawnedAgain() async throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let clock = ContinuousClock()
        let start = clock.now

        let wait = Task { @MainActor in
            await workspace.waitForClaudeAccountSwitchShellPrompt(
                panelId: panelId,
                panel: panel,
                timeout: .seconds(30)
            )
        }
        await Task.yield()
        let replacement = try #require(workspace.respawnTerminalSurface(panelId: panelId, command: nil))
        workspace.updatePanelShellActivityState(panelId: panelId, state: .promptIdle)

        #expect(replacement !== panel)
        #expect(await wait.value == .replaced)
        #expect(clock.now - start < .seconds(10))
    }
}
