import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CompletedRestoredAgentInputRoutingTests {
    @Test
    func completedRestoredAgentStopsAgentSpecificInputRouting() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "completed-agent-input-routing",
            workingDirectory: "/tmp/completed-agent-input-routing",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--resume", "completed-agent-input-routing"],
                workingDirectory: "/tmp/completed-agent-input-routing",
                capturedAt: 1_777_777_777,
                source: "test"
            )
        )
        workspace.restoredAgentSnapshotsByPanelId[panel.id] = snapshot
        workspace.restoredAgentResumeStatesByPanelId[panel.id] = .observedAgentCommandRunning

        let runningContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        #expect(TextBoxAgentDetection.isClaudeCode(context: runningContext))

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .promptIdle)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)
        #expect(workspace.restoredAgentSnapshotsByPanelId[panel.id] != nil)
        let completedContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        #expect(!TextBoxAgentDetection.supportsAgentPrefixes(context: completedContext))
        #expect(
            TextBoxSubmit.dispatchEvents(
                for: [.text("echo one\necho two")],
                terminalAgentContext: completedContext
            ).last == .namedKey(TextBoxTerminalKey.returnKey.rawValue)
        )

        workspace.updatePanelShellActivityState(panelId: panel.id, state: .commandRunning)

        #expect(workspace.restoredAgentResumeStatesByPanelId[panel.id] == .completedAgentExit)
        #expect(
            workspace.restoredAgentSnapshotsByPanelId[panel.id]?.sessionId
                == "completed-agent-input-routing"
        )
        let shellCommandContext = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        #expect(!TextBoxAgentDetection.supportsAgentPrefixes(context: shellCommandContext))
    }
}
