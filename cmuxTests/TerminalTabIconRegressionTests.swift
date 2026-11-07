import Bonsplit
import CmuxSurfaceCatalogModel
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
    @Test(arguments: ["claude_code", "codex", "grok", "agy"])
    func lifecycleOnlyAgentShowsAndClearsItsBrandMark(statusKey: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let expectedAssets = [
            "claude_code": "AgentIcons/Claude",
            "codex": "AgentIcons/Codex",
            "grok": "AgentIcons/Grok",
            "agy": "AgentIcons/Antigravity",
        ]

        workspace.setAgentLifecycle(key: statusKey, panelId: panel.id, lifecycle: .running)
        let runningTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(runningTab.iconAsset == expectedAssets[statusKey])

        #expect(workspace.clearAgentLifecycle(key: statusKey, panelId: panel.id))
        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test(arguments: ["claude_code", "codex"])
    func remoteLifecycleAgentShowsAndClearsItsBrandMark(statusKey: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let remoteKey = RemoteAgentSidebarStatus.statusKeyPrefix + statusKey
        let expectedAssets = [
            "claude_code": "AgentIcons/Claude",
            "codex": "AgentIcons/Codex",
        ]

        workspace.setAgentLifecycle(key: remoteKey, panelId: panel.id, lifecycle: .running)
        let runningTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(runningTab.iconAsset == expectedAssets[statusKey])

        #expect(workspace.clearAgentLifecycle(key: remoteKey, panelId: panel.id))
        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test(arguments: ["claude", "codex"])
    func feedAttentionAgentShowsAndClearsItsBrandMark(source: String) throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let attentionKey = FeedCoordinator.attentionStatusKey(forSource: source)
        let expectedAssets = [
            "claude": "AgentIcons/Claude",
            "codex": "AgentIcons/Codex",
        ]

        workspace.setAgentLifecycle(key: attentionKey, panelId: panel.id, lifecycle: .needsInput)
        let markedTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(markedTab.iconAsset == expectedAssets[source])

        #expect(workspace.clearAgentLifecycle(key: attentionKey, panelId: panel.id))
        try expectNoAgentMark(workspace: workspace, panel: panel, tabId: tabId)
    }

    @MainActor
    @Test func catalogOwnedRemoteIconSurvivesLifecycleSync() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let catalog = SurfaceCatalog.shared
        let resource = SurfaceResourceID(
            machine: .ssh("terminal-tab-icon-regression"),
            kind: .terminal,
            key: "terminal-tab-icon-regression"
        )
        catalog.record(SurfaceProjection(resource: resource, workspaceID: workspace.id, panelID: panel.id))
        defer { catalog.endProjections(panelID: panel.id, reason: .replaced) }

        workspace.bonsplitController.updateTab(tabId, iconAsset: .some("AgentIcons/Codex"))
        let remoteKey = RemoteAgentSidebarStatus.statusKeyPrefix + "codex"
        workspace.setAgentLifecycle(key: remoteKey, panelId: panel.id, lifecycle: .running)
        #expect(workspace.clearAgentLifecycle(key: remoteKey, panelId: panel.id))

        let tab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(tab.iconAsset == "AgentIcons/Codex")
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
        // The resumed agent marks the tab, so the check below cannot pass
        // just because no mark was ever applied.
        let runningTab = try #require(workspace.bonsplitController.tab(tabId))
        #expect(runningTab.iconAsset == "AgentIcons/Codex")

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
