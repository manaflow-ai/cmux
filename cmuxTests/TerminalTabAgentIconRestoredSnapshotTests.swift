import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7822:
/// quitting a live agent session back to a plain shell must return the tab to
/// the plain terminal icon — for every agent brand — while app-relaunch
/// restored panels and pending auto-resume panels keep their brand mark.
@MainActor
struct TerminalTabAgentIconRestoredSnapshotTests {
    private func agentSnapshot(
        kind: RestorableAgentKind,
        sessionId: String = "1a1a1a1a-2b2b-3c3c-4d4d-5e5e5e5e5e5e"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionId,
            workingDirectory: "/tmp/cmux-agent-icon-tests",
            launchCommand: nil
        )
    }

    /// The user repro: an agent runs live in the panel (recorded runtime plus
    /// the restorable snapshot a mid-run session persist adopts), then the
    /// user quits it. The agent process dies and the terminal title reverts to
    /// the shell cwd. No shell-activity prompt event is delivered — shell
    /// integration may be absent or its report may arrive late — so the title
    /// update path must return the tab to the plain terminal icon on its own.
    @Test(arguments: [
        (RestorableAgentKind.claude, "claude_code.session-a", "AgentIcons/Claude"),
        (RestorableAgentKind.codex, "codex.session-b", "AgentIcons/Codex"),
        (RestorableAgentKind.opencode, "opencode.session-c", "AgentIcons/OpenCode"),
    ])
    func quittingLiveAgentReturnsTabToPlainTerminalIcon(
        kind: RestorableAgentKind,
        agentPIDKey: String,
        brandAsset: String
    ) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        workspace.recordAgentPID(key: agentPIDKey, pid: 0, panelId: panel.id, refreshPorts: false)
        workspace.setRestoredAgentSnapshotForTesting(agentSnapshot(kind: kind), panelId: panel.id)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == brandAsset)

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "~/manaflow/cmuxterm-hq"))

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == nil)
        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id) == nil)
        #expect(workspace.bonsplitController.tab(tabId)?.iconImageData == nil)
        #expect(workspace.bonsplitController.tab(tabId)?.iconAsset == nil)
    }

    /// Ordering variant of the same exit: the shell already reported an idle
    /// prompt (the agent is gone, its runtime already pruned) before any
    /// session persist ran. The persist still finds the exited session in the
    /// hook index; adopting it must not paint an agent brand icon onto a
    /// plain shell tab.
    @Test func sessionPersistAfterAgentExitDoesNotPaintAgentIconOnPlainShell() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)
        let index = try claudeHookIndex(
            workspaceId: workspace.id,
            panelId: panel.id,
            sessionId: "7b7b7b7b-8c8c-9d9d-0e0e-1f1f1f1f1f1f"
        )
        _ = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == nil)
        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id) == nil)
    }

    /// A session persist while the agent is the foreground command must keep
    /// adopting the indexed snapshot: that adoption is what lets the session
    /// resume after an app relaunch.
    @Test func sessionPersistWhileAgentCommandRunsStillAdoptsSnapshot() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)
        let index = try claudeHookIndex(
            workspaceId: workspace.id,
            panelId: panel.id,
            sessionId: "3d3d3d3d-4e4e-5f5f-6a6a-7b7b7b7b7b7b"
        )
        let snapshot = workspace.sessionSnapshot(includeScrollback: false, restorableAgentIndex: index)

        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id) != nil)
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Claude")
        #expect(snapshot.panels.first { $0.id == panel.id }?.terminal?.agent != nil)
    }

    /// App-relaunch restore with auto-resume off: the panel sits at a plain
    /// shell prompt with a manually resumable agent session, and the brand
    /// icon is intentional. No agent runtime was ever recorded in this app
    /// run, so shell title churn must not clear it.
    @Test func relaunchRestoredManualResumePanelKeepsBrandIcon() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.seedSessionRestoredAgentIconState(
            panelId: panel.id,
            restorableAgent: agentSnapshot(kind: .claude),
            willRunStartupCommand: false,
            willRunStartupInput: false
        )
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Claude")

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "~/manaflow/cmuxterm-hq"))
        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Claude")
    }

    /// A pending auto-resume must survive a stale-runtime prune: leftover dead
    /// agent runtime describes the previous run, not the queued resume, so
    /// pruning it must not tear down the pending restore or its icon.
    @Test func pendingAutoResumePanelKeepsBrandIconThroughStaleRuntimePrune() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        workspace.seedSessionRestoredAgentIconState(
            panelId: panel.id,
            restorableAgent: agentSnapshot(kind: .codex),
            willRunStartupCommand: false,
            willRunStartupInput: true
        )
        workspace.recordAgentPID(key: "codex.previous-run", pid: 0, panelId: panel.id, refreshPorts: false)

        #expect(workspace.updatePanelTitle(panelId: panel.id, title: "~/manaflow/cmuxterm-hq"))

        #expect(workspace.terminalTabAgentIconAsset(forPanelId: panel.id) == "AgentIcons/Codex")
        #expect(workspace.restoredAgentSnapshotForTesting(panelId: panel.id) != nil)
    }

    // MARK: - Claude hook index fixture

    /// Builds a real `RestorableAgentSessionIndex` from an on-disk claude hook
    /// store fixture so tests exercise the same persist-time adoption path the
    /// app runs, then removes the fixture (the index loads eagerly).
    private func claudeHookIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String
    ) throws -> RestorableAgentSessionIndex {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-agent-icon-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let transcriptDir = projectsDir.appendingPathComponent(
            RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(
            to: transcriptDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd.path,
            "pid": NSNull(),
            "updatedAt": 20,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude", "--dangerously-skip-permissions"],
                "workingDirectory": cwd.path,
                "environment": ["CLAUDE_CONFIG_DIR": configDir.path],
                "capturedAt": 20,
                "source": "test",
            ],
        ]
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let storeData = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionId: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try storeData.write(
            to: stateDir.appendingPathComponent("claude-hook-sessions.json", isDirectory: false),
            options: .atomic
        )

        return RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
    }
}
