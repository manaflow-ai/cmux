import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What `session_priority.get` and `.status` report for one workspace: no target while cmux
/// leaves the workspace or every one of its Claude panes alone, so the CLI shows no arrow to an
/// effort it will not apply.
@MainActor
struct SessionPriorityStatusSnapshotTests {
    private let workspaceId = UUID()

    private var entry: SessionPriorityPlan.Entry {
        SessionPriorityPlan.Entry(
            workspaceId: workspaceId,
            tier: .slow,
            difficulty: .normal,
            difficultySource: .default,
            target: SessionPriorityTarget(effort: .medium)
        )
    }

    private func pane(_ state: SessionPriorityPaneState) -> SessionPrioritySnapshot.Pane {
        SessionPrioritySnapshot.Pane(surfaceId: UUID(), sessionId: "s1", currentEffort: nil, state: state, detail: nil)
    }

    private func snapshot(
        manualFlag: Bool = false,
        panes: [SessionPriorityPaneState],
        enabled: Bool = true
    ) -> SessionPrioritySnapshot {
        let priority = SessionPriorityWorkspaceState()
        priority.isManual = manualFlag
        return SessionPrioritySnapshot(
            workspaceId: workspaceId,
            priority: priority,
            entry: enabled ? entry : nil,
            panes: enabled ? panes.map(pane) : [],
            enabled: enabled
        )
    }

    /// `claude --effort low` (or a `/effort` cmux saw) leaves the workspace alone without the flag.
    @Test
    func paneSignalReportsNoTarget() {
        let launched = snapshot(panes: [.manual(.launchArgumentEffort)])
        let typed = snapshot(panes: [.manual(.userCommandOnScreen)])

        #expect(!launched.isManual)
        #expect(launched.manualSignal == .launchArgumentEffort)
        #expect(launched.target == nil)
        #expect(launched.tier == .slow)
        #expect(typed.manualSignal == .userCommandOnScreen)
        #expect(typed.target == nil)
    }

    /// With two Claude panes and one left alone, cmux still restarts the other to the target.
    @Test
    func oneManualPaneOfTwoStillReportsTheTarget() {
        let mixed = snapshot(panes: [.manual(.launchArgumentEffort), .upToDate])
        let bothManual = snapshot(panes: [.manual(.launchArgumentEffort), .manual(.userCommandOnScreen)])

        #expect(mixed.manualSignal == .launchArgumentEffort)
        #expect(mixed.target == SessionPriorityTarget(effort: .medium))
        #expect(bothManual.target == nil)
    }

    @Test
    func manualFlagReportsNoTarget() {
        let flagged = snapshot(manualFlag: true, panes: [.upToDate])

        #expect(flagged.isManual)
        #expect(flagged.manualSignal == .flag)
        #expect(flagged.target == nil)
    }

    @Test
    func adjustedWorkspaceReportsItsTarget() {
        let adjusted = snapshot(panes: [.upToDate, .held(.draft)])

        #expect(adjusted.manualSignal == nil)
        #expect(adjusted.target == SessionPriorityTarget(effort: .medium))
    }

    @Test
    func offReportsNoTargetSignalOrPanes() {
        let off = snapshot(manualFlag: true, panes: [.manual(.launchArgumentEffort)], enabled: false)

        #expect(off.tier == nil)
        #expect(off.isManual)
        #expect(off.manualSignal == nil)
        #expect(off.target == nil)
        #expect(off.panes.isEmpty)
    }
}
