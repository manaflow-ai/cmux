import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
    func activeAgentKeepsReleaseTerminalIcon(statusKey: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(
            key: "\(statusKey).terminal-icon-regression",
            pid: pid_t(ProcessInfo.processInfo.processIdentifier),
            panelId: panel.id,
            refreshPorts: false
        )

        try assertReleaseTerminalIcon(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test func agentProcessTitleKeepsReleaseTerminalIcon() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "codex --yolo"))

        try assertReleaseTerminalIcon(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test func restoredAgentKeepsReleaseTerminalIcon() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.restoredAgentSnapshotsByPanelId[panel.id] = restoredAgentSnapshot(kind: .codex)
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .awaitingAutoResumeCommand
        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)

        try assertReleaseTerminalIcon(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    private func assertReleaseTerminalIcon(
        workspace: Workspace,
        panel: TerminalPanel,
        tabId: TabID
    ) throws {
        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.icon == "terminal.fill")
        #expect(tab.icon == panel.displayIcon)
        #expect(tab.iconImageData == nil)
        #expect(tab.iconAsset == nil)
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
