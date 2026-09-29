import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A remote viewer (another Mac or the phone) attaches to a terminal through
/// `mobile.terminal.replay`. An agent terminal that Agent Hibernation tore down
/// has no runtime, so the replay was empty and no output ever followed: the
/// viewer showed a blank pane with no disconnect overlay.
@MainActor
@Suite("Mobile terminal replay of hibernated agents", .serialized)
struct MobileTerminalReplayHibernationTests {
    @Test func replayResumesHibernatedAgentTerminal() async throws {
        try await withAppContext { workspace in
            let (panelId, panel) = try hibernateFocusedAgent(in: workspace)

            let result = TerminalController.shared.v2MobileTerminalReplay(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ])
            guard case .ok = result else {
                Issue.record("Expected replay success, got \(result)")
                return
            }

            #expect(
                !panel.isAgentHibernated,
                "Attaching a remote viewer must resume the agent, like selecting its tab"
            )
            #expect(workspace.restoredAgentResumeStatesByPanelId[panelId] == .awaitingAutoResumeCommand)
        }
    }

    @Test func replayHydratesTheRuntimeBeforeReturningItsCurrentState() async throws {
        try await withAppContext { workspace in
            let (panelId, _) = try hibernateFocusedAgent(in: workspace)

            let result = TerminalController.shared.v2MobileTerminalReplay(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ])
            guard case let .ok(payload) = result else {
                Issue.record("Expected replay success, got \(result)")
                return
            }

            #expect(
                payload["render_grid"] != nil ||
                    payload["snapshot_data_b64"] != nil ||
                    payload["data_b64"] != nil,
                "A successful remote replay must carry terminal state, not an empty attach"
            )
        }
    }

    @Test func rejectedReplayLeavesHibernatedAgentAsleep() async throws {
        try await withAppContext { workspace in
            let (panelId, panel) = try hibernateFocusedAgent(in: workspace)

            let result = TerminalController.shared.v2MobileTerminalReplay(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "client_id": "remote-viewer",
            ])
            guard case .err(let code, _, _) = result else {
                Issue.record("Expected a rejected viewport report, got \(result)")
                return
            }

            #expect(code == "invalid_params")
            #expect(panel.isAgentHibernated, "A rejected attach must not wake the agent")
        }
    }

    private func hibernateFocusedAgent(in workspace: Workspace) throws -> (UUID, TerminalPanel) {
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId] as? TerminalPanel)
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-remote-replay-resume",
            workingDirectory: "/tmp/cmux-agent-hibernation",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp/cmux-agent-hibernation",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        try #require(workspace.enterAgentHibernation(
            panelId: panelId,
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))
        try #require(panel.isAgentHibernated)
        return (panelId, panel)
    }

    private func withAppContext(
        _ body: @MainActor (Workspace) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(workspace)
        }
    }
}
