import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Whether a terminal tab shows an agent's mark is a design choice; these tests
// do not encode it. They pin #7822: once no agent runs in the panel, the tab
// must not keep an agent mark.
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
        // Whatever the tab shows while the agent runs is out of scope; make
        // sure any mark it would get has been applied before the agent quits.
        workspace.syncTerminalTabAgentIconAsset(forPanelId: panel.id)

        // The agent quits and the shell prompt returns.
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)

        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
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
