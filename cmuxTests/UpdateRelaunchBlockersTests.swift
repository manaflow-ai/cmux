import CmuxAgentChat
import CmuxUpdater
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What an update relaunch would interrupt, mapped from the shared agent classifier's snapshots
/// plus the shell state of panels no agent owns.
@Suite struct UpdateRelaunchBlockersTests {
    private let workspaceID = UUID()

    private func agent(
        _ kind: String = "claude",
        activity: AgentActivity,
        safety: ResumeSafety,
        placement: AgentPanePlacement = .local,
        panelID: UUID = UUID()
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            workspaceID: workspaceID, panelID: panelID, surfaceID: panelID, paneID: nil,
            name: "pane title", agentKind: kind, sessionID: UUID().uuidString, pid: 42,
            placement: placement, activity: activity,
            assessment: ResumeSafetyAssessment(safety: safety, reasons: [])
        )
    }

    private func shell(_ state: PanelShellActivityState?, panelId: UUID = UUID(), remote: Bool = false) -> UpdateRelaunchShellPanel {
        UpdateRelaunchShellPanel(panelId: panelId, shellActivity: state, isRemote: remote)
    }

    private func blockers(
        _ agents: [AgentActivitySnapshot],
        shells: [UpdateRelaunchShellPanel] = []
    ) -> UpdateRelaunchBlockers {
        AppDelegate.updateRelaunchBlockers(
            agents: agents,
            workspaceTitles: [workspaceID: "work"],
            shellPanels: shells
        )
    }

    @Test func takesTheClassifierSafetyForLocalAgents() {
        let bash = AgentActivity.Tool(name: "Bash", command: "swift build")
        let result = blockers([
            agent(activity: AgentActivity(kind: .tool, tool: bash, source: .hook), safety: .risky),
            agent("codex", activity: AgentActivity(kind: .thinking, source: .hook), safety: .care),
            agent(activity: AgentActivity(kind: .idle, source: .hook), safety: .safe),
        ])

        #expect(result.agents.map(\.safety) == [.risky, .care, .safe])
        #expect(result.agents.map(\.name) == ["Claude Code", "Codex", "Claude Code"])
        #expect(result.agents.map(\.location) == ["work", "work", "work"])
        #expect(result.agents.map(\.activity) == ["swift build", "Thinking", "Idle"])
        #expect(result.riskyAgents.count == 1)
    }

    @Test func aThinkingAgentDoesNotNeedConfirmation() {
        let result = blockers([agent(activity: AgentActivity(kind: .thinking, source: .hook), safety: .care)])

        #expect(!result.needsConfirmation)
    }

    @Test func agentsThatSurviveTheRelaunchAreSafe() {
        let result = blockers([
            agent(
                activity: AgentActivity(kind: .tool, tool: .init(name: "Bash", command: "make"), source: .hook),
                safety: .risky,
                placement: .ssh(host: nil)
            ),
            agent(activity: AgentActivity(kind: .thinking, source: .hook), safety: .care, placement: .cloud),
        ])

        #expect(result.agents.map(\.safety) == [.safe, .safe])
        #expect(result.agents.allSatisfy { $0.activity == "Keeps running on the remote host" })
        #expect(!result.needsConfirmation)
    }

    @Test func activityLinePrefersQuestionsThenCommandThenToolThenKind() {
        let long = "xcodebuild -scheme cmux   -configuration Debug\n-destination platform=macOS build-for-testing test"
        let permission = AgentActivity(kind: .permission, tool: .init(name: "Bash", command: "rm -rf build"), source: .hook)
        let longLine = AppDelegate.updateRelaunchActivityLine(AgentActivity(kind: .tool, tool: .init(name: "Bash", command: long), source: .hook))

        #expect(AppDelegate.updateRelaunchActivityLine(permission) == "Waiting for your permission")
        #expect(AppDelegate.updateRelaunchActivityLine(AgentActivity(kind: .question, source: .hook)) == "Waiting for your answer")
        #expect(longLine.count == AppDelegate.updateRelaunchCommandLimit)
        #expect(longLine.hasPrefix("xcodebuild -scheme cmux -configuration Debug -destination"))
        #expect(longLine.hasSuffix("\u{2026}"))
        #expect(AppDelegate.updateRelaunchActivityLine(AgentActivity(kind: .tool, tool: .init(name: "Edit"), source: .hook)) == "Edit")
        #expect(AppDelegate.updateRelaunchActivityLine(AgentActivity(kind: .subagents, source: .hook)) == "Running subagents")
    }

    @Test func countsLocalCommandsOnlyInPanelsWithoutALiveAgent() {
        let agentPanel = UUID()
        let endedPanel = UUID()
        let result = blockers(
            [
                agent(activity: AgentActivity(kind: .idle, source: .hook), safety: .safe, panelID: agentPanel),
                agent(activity: AgentActivity(kind: .ended, source: .hook), safety: .safe, panelID: endedPanel),
            ],
            shells: [
                shell(.commandRunning, panelId: agentPanel),
                shell(.commandRunning, panelId: endedPanel),
                shell(.commandRunning),
                shell(.commandRunning, remote: true),
                shell(.promptIdle),
                shell(nil),
            ]
        )

        #expect(result.agents.count == 1)
        #expect(result.runningCommandCount == 2)
        #expect(result.needsConfirmation)
    }
}
