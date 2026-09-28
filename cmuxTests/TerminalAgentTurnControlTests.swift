import AppKit
import CmuxAgentJournal
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent turn interrupt target")
struct AgentTurnInterruptTargetTests {
    @Test func resolvesOnlyRunningSupportedAgents() {
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .running]) == .claudeCode)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["codex": .running]) == .codex)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .idle]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["claude_code": .needsInput]) == nil)
        // Agents whose interrupt key is unverified get no button.
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: ["opencode": .running]) == nil)
        #expect(AgentTurnInterruptTarget.resolve(statusKeyedStates: [:]) == nil)
    }

    /// The journal settles the session it has running on the surface, found
    /// from its own fold rather than the hook store.
    @Test func journalInterruptSettlesTheRunningSessionOnTheSurface() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-turn-control-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("journal.sqlite3", isDirectory: false)
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        let surface = UUID()
        let workspace = UUID()
        let started = AgentJournalEventDraft(
            eventId: "turn-started",
            kind: .turnStarted,
            occurredAtMs: 1,
            source: "claude",
            agentKey: "claude_code",
            sessionId: "session-1",
            workspaceId: workspace.uuidString,
            surfaceId: surface.uuidString
        )
        let json = try #require(String(data: JSONEncoder().encode(started), encoding: .utf8))
        #expect(center.handleAppendCommand(json) == "OK 1")

        center.recordUserInterrupt(surfaceId: surface, workspaceId: workspace, agentKey: "claude_code", source: "claude")

        var interrupt: AgentJournalEventDraft?
        for _ in 0..<100 where interrupt == nil {
            try await Task.sleep(for: .milliseconds(20))
            let store = try AgentJournalStore(databaseURL: url)
            interrupt = try store.events(afterSequence: 1, limit: 10)
                .map(\.draft)
                .first { $0.nativeEvent == AgentJournalEventDraft.userInterruptNativeEvent }
            store.close()
        }
        let settled = try #require(interrupt, "The interrupt is journaled for the running session")
        #expect(settled.sessionId == "session-1")
        #expect(settled.kind == .turnCompleted)
        #expect(settled.surfaceId == surface.uuidString)
    }

    @Test func onlyClaudeSettlesItsTurnInTheJournal() {
        #expect(AgentTurnInterruptTarget.claudeCode.settlesTurnInJournal)
        #expect(!AgentTurnInterruptTarget.codex.settlesTurnInJournal)
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
    func clickingStopTwiceQuicklySendsOneEscape() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.hostedView.agentTurnControlView.clickStopForTesting()

        fixture.panel.hostedView.agentTurnControlView.clickStopForTesting()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 1, "A quick second click sends no second Escape")
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
