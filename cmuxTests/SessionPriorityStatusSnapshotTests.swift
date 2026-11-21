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

    /// The difficulty hook's probe reports this as `adjustable`, so a workspace cmux leaves
    /// alone costs no rating call.
    @Test
    func adjustableOnlyWhileThereIsATarget() {
        #expect(snapshot(panes: [.upToDate]).isAdjustable)
        #expect(snapshot(panes: [.manual(.launchArgumentEffort), .upToDate]).isAdjustable)
        #expect(!snapshot(panes: [.manual(.launchEnvironmentEffort)]).isAdjustable)
        #expect(!snapshot(panes: [.manual(.userCommandOnScreen)]).isAdjustable)
        #expect(!snapshot(manualFlag: true, panes: [.upToDate]).isAdjustable)
        #expect(!snapshot(panes: [.upToDate], enabled: false).isAdjustable)
    }

    // MARK: - Before the coordinator first decides a pane (ruling R37)

    private func reported(
        _ state: SessionPriorityCoordinatorState,
        panelId: UUID,
        sessionId: String? = "s1",
        arguments: [String] = ["claude", "--session-id", "s1"],
        environment: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:]
    ) -> SessionPriorityPaneState {
        state.reportedPaneState(
            panelId: panelId,
            sessionId: sessionId,
            workspaceMarkedManual: false,
            launchArguments: arguments,
            launchEnvironment: environment,
            workspaceEnvironment: workspaceEnvironment
        )
    }

    /// A fresh `claude --effort max` has no pane record until its first turn end; its launch
    /// already says cmux leaves it alone, so the rating hook's probe says not adjustable.
    @Test
    func freshLaunchSignalPaneIsNotAdjustable() {
        let state = SessionPriorityCoordinatorState()
        let launchedWithEffort = reported(state, panelId: UUID(), arguments: ["claude", "--session-id", "s1", "--effort", "max"])
        let launchVariable = reported(state, panelId: UUID(), environment: [ClaudeEffortLevel.environmentKey: "max"])
        let workspaceVariable = reported(state, panelId: UUID(), workspaceEnvironment: [ClaudeEffortLevel.environmentKey: "high"])

        #expect(launchedWithEffort == .manual(.launchArgumentEffort))
        #expect(!snapshot(panes: [launchedWithEffort]).isAdjustable)
        #expect(launchVariable == .manual(.launchEnvironmentEffort))
        #expect(!snapshot(panes: [launchVariable]).isAdjustable)
        #expect(workspaceVariable == .manual(.workspaceEnvironmentEffort))
        #expect(!snapshot(panes: [workspaceVariable]).isAdjustable)
    }

    /// A plain launch, or one carrying the level cmux set and marked, is adjusted from the start.
    @Test
    func freshPlainPaneIsAdjustable() {
        let state = SessionPriorityCoordinatorState()
        let plain = reported(state, panelId: UUID())
        let cmuxOwnLevel = reported(state, panelId: UUID(), environment: [
            ClaudeEffortLevel.environmentKey: "high",
            ClaudeEffortLevel.sessionPriorityMarkerKey: "high",
        ])

        #expect(plain == .upToDate)
        #expect(snapshot(panes: [plain]).isAdjustable)
        #expect(cmuxOwnLevel == .upToDate)
        #expect(snapshot(panes: [cmuxOwnLevel]).isAdjustable)
    }

    /// Turning the feature off drops the pane records; on again, the pane's launch still says
    /// cmux leaves it alone before its next turn.
    @Test
    func launchSignalPaneStaysNotAdjustableAfterOffAndOn() {
        var state = SessionPriorityCoordinatorState()
        let panelId = UUID()
        let decided = state.noteDecision(.leave(.manual(.launchArgumentEffort)), panelId: panelId, workspaceId: workspaceId, sessionId: "s1")
        #expect(decided == .manual(.launchArgumentEffort))

        _ = state.disable()
        let afterReenable = reported(state, panelId: panelId, arguments: ["claude", "--effort", "max"])

        #expect(state.records[panelId] == nil)
        #expect(afterReenable == .manual(.launchArgumentEffort))
        #expect(!snapshot(panes: [afterReenable]).isAdjustable)
    }

    /// A session end keeps only the pane's last restart attempt; the next Claude started in the
    /// pane is not decided yet, so its own launch counts.
    @Test
    func paneKeptOnlyForItsLastAttemptReportsItsNewLaunch() {
        var state = SessionPriorityCoordinatorState()
        let panelId = UUID()
        let target = SessionPriorityTarget(effort: .high)
        state.noteRestartStarted(panelId: panelId, sessionId: "s1", target: target, nowMs: 0)
        _ = state.noteResult(panelId: panelId, .applied(sessionID: "s1"), nowMs: 1_000)
        state.noteSessionStarted(panelId: panelId, sessionId: "s1", occurredAtMs: 2_000)
        state.noteSessionEnded(panelId: panelId, occurredAtMs: 3_000)
        #expect(state.records[panelId]?.lastAttempt != nil)

        let relaunched = reported(state, panelId: panelId, arguments: ["claude", "--effort", "max"])

        #expect(relaunched == .manual(.launchArgumentEffort))
    }

    /// A Claude that died without a `SessionEnd` leaves its record; a new `claude --effort max` in
    /// the pane is another session, which the record does not decide, so its launch counts. A
    /// record waiting for its restarted Claude's start still counts while the index lags.
    @Test
    func recordForAnotherSessionDoesNotDecideTheNewOne() {
        var state = SessionPriorityCoordinatorState()
        let panelId = UUID()
        let decided = state.noteDecision(.leave(.upToDate), panelId: panelId, workspaceId: workspaceId, sessionId: "s1")
        #expect(decided == .upToDate)

        let newSession = reported(state, panelId: panelId, sessionId: "s2", arguments: ["claude", "--effort", "max"])
        let sameSession = reported(state, panelId: panelId, sessionId: "s1", arguments: ["claude", "--effort", "max"])

        #expect(newSession == .manual(.launchArgumentEffort))
        #expect(!snapshot(panes: [newSession]).isAdjustable)
        #expect(sameSession == .upToDate, "the record still decides its own session")

        let restarting = UUID()
        state.noteRestartStarted(panelId: restarting, sessionId: "s3", target: SessionPriorityTarget(effort: .high), nowMs: 0)
        #expect(reported(state, panelId: restarting, sessionId: "s0") == .applying)
    }

    /// Once the coordinator decided the pane, its record is what the status reports.
    @Test
    func decidedPaneReportsItsRecord() {
        var state = SessionPriorityCoordinatorState()
        let panelId = UUID()
        _ = state.noteDecision(.leave(.upToDate), panelId: panelId, workspaceId: workspaceId, sessionId: "s1")
        state.records[panelId]?.state = .held(.draft)

        #expect(reported(state, panelId: panelId) == .held(.draft))
    }
}
