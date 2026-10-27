import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The times the session priority coordinator keeps: one debounced reconcile pass, the only one
/// that queues restarts (ruling R18); each pane's last turn end, where its quiet window starts
/// (ruling R17); and when cmux last set aside the user's own `/effort` and `/model` on a pane,
/// which bounds the transcript probe (ruling R14).
///
/// `#expect` captures its operands, so each mutating call's result is bound first.
struct SessionPriorityReconcileTimingTests {
    private let pane = UUID()
    private let workspace = UUID()

    // MARK: - The debounced pass

    @Test
    func triggersWithinTheDebounceShareOneReconcile() {
        var state = SessionPriorityCoordinatorState()

        let firstDue = state.requestReconcile(nowMs: 0, settles: false)
        let secondDue = state.requestReconcile(nowMs: 1_500, settles: false)
        let early = state.takeReconcileDue(nowMs: 1_999)
        let due = state.takeReconcileDue(nowMs: 2_000)
        let again = state.takeReconcileDue(nowMs: 2_001)

        #expect(firstDue == 2_000)
        #expect(secondDue == 2_000)
        #expect(!early)
        #expect(due)
        #expect(!again)
        #expect(state.reconcileDueAtMs == nil)
    }

    /// A move or a settings change gives the gesture 2 s to settle; a turn end that comes in
    /// between joins the same pass instead of running one against the mid-gesture rank.
    @Test
    func aUserMovePushesThePendingPassBack() {
        var state = SessionPriorityCoordinatorState()

        _ = state.requestReconcile(nowMs: 0, settles: true)
        let movedAgain = state.requestReconcile(nowMs: 1_500, settles: true)
        let turnEnded = state.requestReconcile(nowMs: 3_000, settles: false)
        let atFirstDeadline = state.takeReconcileDue(nowMs: 2_000)
        let atLastMove = state.takeReconcileDue(nowMs: 3_500)

        #expect(movedAgain == 3_500)
        #expect(turnEnded == 3_500)
        #expect(!atFirstDeadline)
        #expect(atLastMove)
    }

    /// The user drags a workspace to the top and back within 2 s. Had the first move reconciled
    /// at once, its pane would have been queued for the urgent target.
    @Test
    func aReorderThereAndBackWithinTheDebounceQueuesNothing() {
        let top = UUID()
        let original = [top, workspace]
        let moved = [workspace, top]
        let urgent = SessionPriorityTarget(effort: .high)
        let slow = SessionPriorityTarget(effort: .medium)
        var state = SessionPriorityCoordinatorState()
        var order = original

        func reconcile() {
            let plan = SessionPriorityPlan.make(
                effectiveOrder: order,
                workspaces: [
                    top: input(top),
                    workspace: input(workspace),
                ],
                urgentCount: 1,
                matrix: matrix(urgent: urgent, slow: slow)
            )
            let action = SessionPriorityPaneDecision.decide(
                target: plan[workspace]?.target,
                manualSignal: nil,
                stickyManual: nil,
                currentEffort: slow.effort,
                currentModel: nil,
                awaitingSessionStart: false
            )
            _ = state.noteDecision(action, panelId: pane, workspaceId: workspace, sessionId: "s1")
        }

        order = moved
        _ = state.requestReconcile(nowMs: 0, settles: true)
        order = original
        _ = state.requestReconcile(nowMs: 1_200, settles: true)
        for nowMs in stride(from: Int64(0), through: 4_000, by: 100) where state.takeReconcileDue(nowMs: nowMs) {
            reconcile()
        }
        #expect(state.queue.isEmpty)

        // The hazard the debounce removes: a pass against the moved rank queues the pane.
        order = moved
        reconcile()
        #expect(!state.queue.isEmpty)
    }

    @Test
    func disablingDropsThePendingPass() {
        var state = SessionPriorityCoordinatorState()
        _ = state.requestReconcile(nowMs: 0, settles: false)

        _ = state.disable()
        let due = state.takeReconcileDue(nowMs: 10_000)

        #expect(state.reconcileDueAtMs == nil)
        #expect(!due)
    }

    // MARK: - Turn ends

    @Test
    func theQuietWindowRunsFromTheLastTurnEnd() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000)
        state.noteTurnEnded(panelId: pane, nowMs: 50_000)

        func inside(_ nowMs: Int64) -> Bool {
            SessionPriorityApplyGate.isInsideQuietWindow(
                nowMs: nowMs,
                receivedInputAfter: { _ in false },
                lastTurnEndMs: state.lastTurnEndedAtMs[pane]
            )
        }

        #expect(state.lastTurnEndedAtMs[pane] == 50_000)
        #expect(inside(59_999))
        #expect(!inside(60_000))
    }

    /// Turning the feature off and on right after a turn end still waits out the window, and a
    /// closed pane is forgotten.
    @Test
    func turnEndsOutliveDisableButNotThePane() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000)

        _ = state.disable()
        #expect(state.lastTurnEndedAtMs[pane] == 1_000)

        state.retainPanes([])
        #expect(state.lastTurnEndedAtMs[pane] == nil)
    }

    // MARK: - Dismissals of the user's own changes

    @Test(arguments: [
        SessionPriorityApplyResult.applied(sessionID: "s1"),
        .resumeNotTyped(ClaudeAccountSwitchManualResume(
            command: "claude --resume s1",
            typedInput: "claude --resume s1\n",
            paneWasReplaced: false
        )),
    ])
    func aRestartDismissesEarlierChanges(result: SessionPriorityApplyResult) {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: SessionPriorityTarget(effort: .high), nowMs: 1_000)

        _ = state.noteResult(panelId: pane, result, nowMs: 4_000)

        #expect(state.manualDismissedAtMs[pane] == 4_000)
    }

    @Test(arguments: [
        SessionPriorityApplyResult.held(.backgroundWork),
        .refused(.noConversationYet),
        .respawnFailed,
    ])
    func aRestartThatReplacedNothingDismissesNothing(result: SessionPriorityApplyResult) {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: SessionPriorityTarget(effort: .high), nowMs: 1_000)

        _ = state.noteResult(panelId: pane, result, nowMs: 4_000)

        #expect(state.manualDismissedAtMs[pane] == nil)
    }

    /// "Adjust Claude Effort Automatically" sets aside every change made so far on the
    /// workspace's panes, including one cmux has not looked at yet.
    @Test
    func adjustAutomaticallyDismissesEveryPane() {
        var state = SessionPriorityCoordinatorState()
        let unseen = UUID()
        state.follow(panelId: pane, sessionId: "s1")

        state.clearStickyManual(panelIds: [pane, unseen], nowMs: 7_000)

        #expect(state.manualDismissedAtMs[pane] == 7_000)
        #expect(state.manualDismissedAtMs[unseen] == 7_000)
        _ = state.disable()
        #expect(state.manualDismissedAtMs[pane] == 7_000)
    }

    /// A `/effort` found in the transcript right before a restart leaves the pane alone for
    /// the session, like one seen on screen, without spending the attempt.
    @Test
    func aTranscriptChangeMakesThePaneStickyManual() {
        var state = SessionPriorityCoordinatorState()
        let high = SessionPriorityTarget(effort: .high)
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 1_000)

        state.noteManualChangeInTranscript(panelId: pane)
        let mayAttempt = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)

        #expect(state.records[pane]?.stickyManual == .userCommandOnScreen)
        #expect(state.records[pane]?.state == .manual(.userCommandOnScreen))
        #expect(state.records[pane]?.awaitingSessionStartUntilMs == nil)
        #expect(mayAttempt)
    }

    // MARK: - Helpers

    private func input(_ id: UUID) -> SessionPriorityPlan.WorkspaceInput {
        SessionPriorityPlan.WorkspaceInput(
            id: id,
            hasClaudePane: true,
            difficulty: .normal,
            difficultySource: .default,
            isManual: false
        )
    }

    private func matrix(urgent: SessionPriorityTarget, slow: SessionPriorityTarget) -> SessionPriorityMatrix {
        let json = """
        {"urgent":{"normal":{"effort":"\(urgent.effort?.rawValue ?? "")"}},\
        "slow":{"normal":{"effort":"\(slow.effort?.rawValue ?? "")"}}}
        """
        return SessionPriorityMatrix.fromStoredString(json)
    }
}
