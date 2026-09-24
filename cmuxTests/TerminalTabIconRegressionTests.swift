import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// A terminal tab shows an agent's mark only while that agent runs in the panel
// (#13299). These tests pin #7822, that the mark goes once the agent does, and
// that a mark never comes from anything but a running agent.
@Suite(.serialized)
struct TerminalTabIconRegressionTests {
    @MainActor
    @Test(arguments: [
        "claude_code",
        "codex",
        "opencode",
        "pi",
        "omp",
        "grok",
        "rovodev",
        "antigravity",
        "hermes-agent",
    ])
    func clearedAgentLeavesNoAgentMark(statusKey: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let key = "\(statusKey).terminal-icon-regression"

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(
            key: key,
            pid: pid_t(ProcessInfo.processInfo.processIdentifier),
            panelId: panel.id,
            refreshPorts: false
        )
        #expect(workspace.clearAgentPID(key: key, panelId: panel.id, refreshPorts: false))

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    // #13299: a tab whose title merely looks like an agent command gets no
    // agent mark. Only a detected agent process or a running restored agent
    // names the tab.
    @MainActor
    @Test func agentLookingTitleGetsNoAgentMark() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "codex --yolo"))

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test func restoredAgentThatQuitToTheShellLeavesNoAgentMark() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.restoredAgentLifecycle.setSnapshot(
            restoredAgentSnapshot(kind: .codex),
            panelId: panel.id
        )
        workspace.restoredAgentLifecycle.setResumeState(
            .awaitingAutoResumeCommand,
            panelId: panel.id
        )
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .autoResumeCommandRunning)
        // Agent marks are for Cloud terminal tabs only: a local resumed
        // agent keeps the plain terminal icon while it runs, too.
        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)

        // The agent quits and the shell prompt returns.
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    // A restored tab that has not resumed its agent yet shows no agent mark:
    // after a relaunch, a tab waiting to auto-resume or offering a manual
    // resume looks like a plain terminal until the agent command runs.
    @MainActor
    @Test func restoredAgentThatHasNotResumedGetsNoAgentMark() throws {
        for state: Workspace.RestoredAgentResumeState in [.awaitingAutoResumeCommand, .manualResumeAvailable] {
            let workspace = Workspace()
            let panel = try #require(workspace.focusedTerminalPanel)
            let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

            workspace.restoredAgentLifecycle.setSnapshot(
                restoredAgentSnapshot(kind: .codex),
                panelId: panel.id
            )
            workspace.restoredAgentLifecycle.setResumeState(state, panelId: panel.id)
            workspace.syncTerminalTabAgentIconAsset(forPanelId: panel.id)
            #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == state)

            try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
        }
    }

    @MainActor
    private func expectNoAgentMark(
        workspace: Workspace,
        panel: TerminalPanel,
        tabId: TabID
    ) throws {
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.iconAsset == nil)
        #expect(tab.iconImageData == nil)
        #expect(tab.icon == panel.displayIcon)
    }

    private func restoredAgentSnapshot(kind: RestorableAgentKind) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: "\(kind.rawValue)-terminal-tab-icon-session",
            workingDirectory: "/tmp/cmux-terminal-tab-icon",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: kind.rawValue,
                executablePath: "/usr/local/bin/\(kind.rawValue)",
                arguments: ["/usr/local/bin/\(kind.rawValue)"],
                workingDirectory: "/tmp/cmux-terminal-tab-icon",
                environment: nil,
                capturedAt: 1_777_777_777,
                source: "test"
            )
        )
    }
}
