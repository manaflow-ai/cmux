import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A hibernated agent must be visible without opening its pane: the sidebar
/// shows a calm row for the workspace, and Task Manager marks the surface.
@MainActor
@Suite(.serialized)
struct AgentHibernationIndicatorTests {
    private let statusKey = "agent.hibernated"

    @Test
    func hibernatingAnAgentAddsASidebarRowAndWakingRemovesIt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        #expect(workspace.statusEntries[statusKey] == nil)

        panel.agentHibernationPhase = .hibernated(hibernatedState())
        let entry = try #require(workspace.statusEntries[statusKey])
        #expect(entry.icon == "moon.zzz")
        #expect(entry.color == nil)

        panel.agentHibernationPhase = .live
        #expect(workspace.statusEntries[statusKey] == nil)
    }

    @Test
    func theRowCountsEveryHibernatedAgentInTheWorkspace() throws {
        let workspace = Workspace()
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))

        first.agentHibernationPhase = .hibernated(hibernatedState())
        let one = try #require(workspace.statusEntries[statusKey]?.value)
        second.agentHibernationPhase = .hibernated(hibernatedState())
        let two = try #require(workspace.statusEntries[statusKey]?.value)
        #expect(one != two)
        #expect(two.contains("2"))
    }

    @Test
    func closingTheHibernatedPaneRemovesTheRow() throws {
        let workspace = Workspace()
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        second.agentHibernationPhase = .hibernated(hibernatedState())
        #expect(workspace.statusEntries[statusKey] != nil)

        #expect(workspace.closePanel(second.id, force: true))
        #expect(workspace.statusEntries[statusKey] == nil)
    }

    @Test
    func anotherWorkspacesAgentDoesNotAddTheRow() throws {
        let workspace = Workspace()
        let other = Workspace()
        let otherPanel = try #require(other.focusedTerminalPanel)

        otherPanel.agentHibernationPhase = .hibernated(hibernatedState())
        #expect(other.statusEntries[statusKey] != nil)
        #expect(workspace.statusEntries[statusKey] == nil)
    }

    @Test
    func theRowIsNotPersistedInTheSessionSnapshot() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.agentHibernationPhase = .hibernated(hibernatedState())
        #expect(workspace.statusEntries[statusKey] != nil)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        #expect(!snapshot.statusEntries.contains { $0.key == statusKey })
    }

    @Test
    func aPaneStillTerminatingIsNotCountedAsHibernated() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)

        panel.agentHibernationPhase = .terminationFailed(hibernatedState())
        #expect(workspace.statusEntries[statusKey] == nil)
        panel.agentHibernationPhase = .hibernated(hibernatedState())
        #expect(workspace.statusEntries[statusKey] != nil)
    }

    @Test
    func restoringASessionWithAHibernatedAgentShowsTheRow() throws {
        // Restore focuses the saved focused pane and selects each pane's saved
        // tab, and focusing a hibernated pane wakes its agent. Keep the
        // hibernated agent in a background tab so the restore leaves it asleep.
        let source = Workspace()
        let live = try #require(source.focusedTerminalPanel)
        let paneId = try #require(source.paneId(forPanelId: live.id))
        let background = try #require(source.newTerminalSurface(
            inPane: paneId,
            focus: false,
            preserveBonsplitSelectionWhenUnfocused: true
        ))
        let state = hibernatedState()
        source.restoredAgentLifecycle.setSnapshot(state.agent, panelId: background.id)
        background.agentHibernationPhase = .hibernated(state)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        try #require(snapshot.panels.contains { $0.terminal?.hibernation != nil })

        let saved = try #require(snapshot.panels.first { $0.terminal?.hibernation != nil })
        // DIAG(temporary): locate where the restore drops hibernation.
        #expect(saved.terminal?.agent != nil, "DIAG saved agent")
        #expect(saved.terminal?.agent?.resumeCommand != nil, "DIAG saved resumeCommand")
        #expect(saved.terminal?.resumeBinding == nil, "DIAG saved resumeBinding \(String(describing: saved.terminal?.resumeBinding))")
        #expect(snapshot.focusedPanelId == live.id, "DIAG focused \(String(describing: snapshot.focusedPanelId))")

        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(snapshot)
        let restoredPanels = restored.panels.values.compactMap { $0 as? TerminalPanel }
        #expect(restoredPanels.count == 2, "DIAG restored count \(restoredPanels.count)")
        for panel in restoredPanels {
            #expect(panel.id == restored.focusedPanelId || panel.agentHibernationPhase.isSettledHibernation,
                    "DIAG phase \(panel.agentHibernationPhase) focused=\(panel.id == restored.focusedPanelId) resume=\(String(describing: restored.restoredAgentSnapshotsByPanelId[panel.id]))")
        }
        let probe = try #require(restoredPanels.first { $0.id != restored.focusedPanelId })
        #expect(probe.enterAgentHibernation(agent: state.agent, lastActivityAt: Date()), "DIAG direct enter")
        try #require(restoredPanels.contains { $0.agentHibernationPhase.isSettledHibernation })
        #expect(restored.statusEntries[statusKey] != nil)
    }

    @Test
    func resettingTheSidebarKeepsTheRow() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.agentHibernationPhase = .hibernated(hibernatedState())

        workspace.resetSidebarContext()
        #expect(workspace.statusEntries[statusKey] != nil)
    }

    @Test
    func taskManagerDimsAndLabelsAHibernatedSurface() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: topPayload(surfaces: [
            surface(id: "38457A72-7D87-40FC-8ED5-899B59572FD0", index: 1, hibernated: true),
            surface(id: "5D0C1F0A-3C0E-4F43-9E7C-6E3F6A1B2C3D", index: 2, hibernated: false),
        ]))

        let surfaceRows = snapshot.rows.filter { $0.kind == .terminalSurface }
        #expect(surfaceRows.count == 2)
        let hibernated = try #require(surfaceRows.first { $0.title == "surface 1" })
        let live = try #require(surfaceRows.first { $0.title == "surface 2" })
        #expect(hibernated.isDimmed)
        #expect(hibernated.detail.contains("Hibernated"))
        #expect(!live.isDimmed)
        #expect(!live.detail.contains("Hibernated"))
    }

    private func hibernatedState() -> AgentHibernationPanelState {
        AgentHibernationPanelState(
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "indicator-\(UUID().uuidString)",
                workingDirectory: "/tmp"
            ),
            hibernatedAt: Date(),
            lastActivityAt: Date()
        )
    }

    private func surface(id: String, index: Int, hibernated: Bool) -> [String: Any] {
        [
            "id": id,
            "ref": "surface:\(index)",
            "type": "terminal",
            "title": "surface \(index)",
            "agent_hibernated": hibernated,
            "resources": [:] as [String: Any],
        ]
    }

    private func topPayload(surfaces: [[String: Any]]) -> [String: Any] {
        [
            "sample": ["sampled_at": "2026-09-28T12:00:00Z"],
            "totals": [:] as [String: Any],
            "windows": [[
                "id": "window-1",
                "ref": "window:1",
                "resources": [:] as [String: Any],
                "workspaces": [[
                    "id": "7F587C98-0069-4605-B066-F6FB941D54B4",
                    "ref": "workspace:1",
                    "title": "workspace",
                    "resources": [:] as [String: Any],
                    "panes": [[
                        "id": "pane-1",
                        "ref": "pane:1",
                        "resources": [:] as [String: Any],
                        "surfaces": surfaces,
                    ]],
                ]],
            ]],
        ]
    }
}
