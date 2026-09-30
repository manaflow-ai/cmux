import Foundation
import CMUXMobileCore
import GhosttyKit
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

            let result = await TerminalController.shared.v2MobileTerminalReplay(params: [
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
            let panel = try #require(workspace.focusedTerminalPanel)
            try #require(!panel.surface.hasLiveSurface)
            try #require(panel.surface.uiWindow == nil)
            let marker = "REMOTE_HIDDEN_REPLAY_READY"
            panel.surface.onRuntimeReady = { [weak panel] in
                guard let runtime = panel?.surface.surface else { return }
                marker.withCString {
                    ghostty_surface_process_output(runtime, $0, UInt(marker.utf8.count))
                }
            }
            defer { panel.surface.onRuntimeReady = nil }

            let result = await TerminalController.shared.mobileHostHandleRPC(MobileHostRPCRequest(
                id: "hidden-terminal-replay",
                method: "mobile.terminal.replay",
                params: ["workspace_id": workspace.id.uuidString, "surface_id": panel.id.uuidString],
                auth: nil
            ))
            guard case let .ok(rawPayload) = result else {
                Issue.record("Expected replay success, got \(result)")
                return
            }
            let payload = try #require(rawPayload as? [String: Any])
            let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(
                #require(payload["render_grid"], "A cold replay must wait for the runtime's screen")
            )
            #expect(frame.plainRows().joined(separator: "\n").contains(marker))
            #expect(!panel.surface.isRendererPortalVisible)
            #expect(panel.surface.uiWindow == nil, "Remote attach must not reveal the source terminal")
        }
    }

    @Test func replayAdmitsAFirstVisitRestoreBeforeCapturingState() async throws {
        try await withAppContext { workspace in
            let manager = try #require(AppDelegate.shared?.tabManager)
            let heldWorkspace = try #require(manager.addWorkspaceIfActive(
                title: "Held remote replay",
                initialTerminalInput: "echo restored-first-visit\n",
                initialTerminalStartupRestoreAgent: makeAgent(sessionID: "codex-first-visit-replay"),
                select: false,
                eagerLoadTerminal: false,
                initialTerminalStartsOnFirstVisit: true
            ))
            let selectedBeforeReplay = manager.selectedTabId
            #expect(selectedBeforeReplay != heldWorkspace.id)
            let panel = try #require(heldWorkspace.focusedTerminalPanel)
            #expect(heldWorkspace.startupRestorePanelIdsAwaitingFirstVisit.contains(panel.id))
            #expect(panel.surface.isAwaitingStartupRestoreAdmission)
            let marker = "REMOTE_FIRST_VISIT_REPLAY_READY"
            panel.surface.onRuntimeReady = { [weak panel] in
                guard let runtime = panel?.surface.surface else { return }
                marker.withCString {
                    ghostty_surface_process_output(runtime, $0, UInt(marker.utf8.count))
                }
            }
            defer { panel.surface.onRuntimeReady = nil }

            let result = await TerminalController.shared.mobileHostHandleRPC(MobileHostRPCRequest(
                id: "first-visit-replay",
                method: "mobile.terminal.replay",
                params: ["workspace_id": heldWorkspace.id.uuidString, "surface_id": panel.id.uuidString],
                auth: nil
            ))
            guard case let .ok(rawPayload) = result else {
                Issue.record("Expected first-visit replay success, got \(result)")
                return
            }
            let payload = try #require(rawPayload as? [String: Any])
            let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(
                #require(payload["render_grid"], "A first-visit replay must admit the held runtime")
            )
            #expect(frame.plainRows().joined(separator: "\n").contains(marker))
            #expect(heldWorkspace.startupRestorePanelIdsAwaitingFirstVisit.isEmpty)
            #expect(manager.selectedTabId == selectedBeforeReplay, "Remote attach must not reveal the held workspace")
            #expect(panel.surface.uiWindow == nil, "Remote attach must not reveal the source terminal")
        }
    }

    @Test func replayDoesNotReportSuccessWhileRestoreAdmissionIsPending() async throws {
        try await withAppContext { workspace in
            let manager = try #require(AppDelegate.shared?.tabManager)
            let heldWorkspace = try #require(manager.addWorkspaceIfActive(
                title: "Pending remote replay",
                initialTerminalInput: "echo pending-admission\n",
                initialTerminalStartupRestoreAgent: makeAgent(sessionID: "codex-pending-admission"),
                select: false,
                eagerLoadTerminal: false,
                initialTerminalStartsOnFirstVisit: true
            ))
            let panel = try #require(heldWorkspace.focusedTerminalPanel)
            // Leave the surface's lifecycle gate held while removing the
            // first-visit owner entry. This is the same awaitingRestore state
            // produced while deferred agent ownership is still undecided.
            heldWorkspace.startupRestorePanelIdsAwaitingFirstVisit.remove(panel.id)
            #expect(panel.surface.isAwaitingStartupRestoreAdmission)

            let result = await TerminalController.shared.v2MobileTerminalReplay(params: [
                "workspace_id": heldWorkspace.id.uuidString,
                "surface_id": panel.id.uuidString,
            ])

            guard case let .err(code, _, data) = result else {
                Issue.record("Expected a pending-admission error, got \(result)")
                return
            }
            #expect(code == "surface_unavailable")
            let errorData = data as? [String: Any]
            #expect(errorData?["reason"] as? String == "awaiting_restore")
        }
    }

    @Test func rejectedReplayLeavesHibernatedAgentAsleep() async throws {
        try await withAppContext { workspace in
            let (panelId, panel) = try hibernateFocusedAgent(in: workspace)

            let result = await TerminalController.shared.v2MobileTerminalReplay(params: [
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
        let agent = makeAgent(sessionID: "codex-remote-replay-resume")
        try #require(workspace.enterAgentHibernation(
            panelId: panelId,
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        ))
        try #require(panel.isAgentHibernated)
        return (panelId, panel)
    }

    private func makeAgent(sessionID: String) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
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
