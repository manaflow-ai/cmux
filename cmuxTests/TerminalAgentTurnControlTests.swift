import AppKit
import CmuxAgentJournal
import CmuxMobileHost
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent turn interrupt target")
struct AgentTurnInterruptTargetTests {
    private let surface = UUID()
    private let fallbackWorkspace = UUID()

    private func entry(
        _ sessionID: String,
        surface: UUID?,
        workspace: UUID? = nil,
        updatedAt: TimeInterval
    ) -> AgentChatHookSessionStore.Entry {
        AgentChatHookSessionStore.Entry(
            sessionID: sessionID,
            workspaceID: workspace?.uuidString,
            surfaceID: surface?.uuidString,
            workingDirectory: nil,
            transcriptPath: nil,
            pid: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @Test func resolvesOnlyRunningSupportedAgents() {
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .running]) == .claudeCode)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["codex": .running]) == .codex)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .idle]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .needsInput]) == nil)
        // Agents whose interrupt key is unverified get no button.
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["opencode": .running]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: [:]) == nil)
    }

    @Test func interruptSettlesNewestSessionOnTheSurface() throws {
        let hookWorkspace = UUID()
        let entries = [
            entry("old", surface: surface, updatedAt: 10),
            entry("current", surface: surface, workspace: hookWorkspace, updatedAt: 20),
            entry("elsewhere", surface: UUID(), updatedAt: 30),
        ]
        let draft = try #require(AgentTurnInterruptTarget.claudeCode.interruptDraft(
            surfaceID: surface,
            fallbackWorkspaceID: fallbackWorkspace,
            entries: entries
        ))
        #expect(draft.sessionId == "current")
        #expect(draft.source == "claude")
        #expect(draft.agentKey == "claude_code")
        #expect(draft.kind == .turnCompleted)
        #expect(draft.workspaceId == hookWorkspace.uuidString)
        #expect(draft.surfaceId == surface.uuidString)
        #expect(draft.validationProblem() == nil)
    }

    @Test func interruptWithoutBoundSessionJournalsNothing() {
        let entries = [entry("elsewhere", surface: UUID(), updatedAt: 30)]
        #expect(AgentTurnInterruptTarget.codex.interruptDraft(
            surfaceID: surface,
            fallbackWorkspaceID: fallbackWorkspace,
            entries: entries
        ) == nil)
    }
}

@MainActor
@Suite("Terminal agent Stop button", .serialized)
struct TerminalAgentTurnControlTests {
    private let setting = AgentActionsCatalogSection().turnControl

    @Test
    func stopShowsOnlyWhileEnabledAndRunning() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        let view = fixture.panel.hostedView.agentTurnControlView

        #expect(view.isHidden, "No agent is running yet")
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        #expect(!view.isHidden, "A running Claude turn shows Stop")
        #expect(view.target == .claudeCode)

        setting.set(false, in: .standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(view.isHidden, "Turning the setting off hides Stop mid-turn")
        setting.set(true, in: .standard)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(!view.isHidden)

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        #expect(view.isHidden, "An idle agent has no turn to stop")
        _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id)
    }

    @Test
    func stopIsHiddenByDefault() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.removeValue(in: .standard)
        fixture.workspace.setAgentLifecycle(key: "codex", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "codex", panelId: fixture.panel.id) }
        #expect(fixture.panel.hostedView.agentTurnControlView.isHidden)
    }

    @Test
    func clickingStopSendsOneEscapeToTheRunningAgent() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.hostedView.agentTurnControlView.clickStopForTesting()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 1, "Stop sends exactly one Escape")
    }

    @Test
    func staleStopClickSendsNothing() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        // The agent finished before the click landed.
        fixture.panel.interruptAgentTurn(.claudeCode)

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents, "No Escape reaches a pane whose agent is not running")
    }

    private func makeWorkspaceFixture() throws -> (
        windowID: UUID,
        workspace: Workspace,
        panel: TerminalPanel
    ) {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        do {
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelID))
            panel.surface.releaseHostedSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
