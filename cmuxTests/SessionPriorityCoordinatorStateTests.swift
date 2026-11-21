import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What the session priority coordinator remembers between events: restarts in flight, holds,
/// sticky manual signals, and the one restart attempt per session and target (ruling R9).
///
/// `#expect` captures its operands, so each mutating call's result is bound first.
struct SessionPriorityCoordinatorStateTests {
    private let pane = UUID()
    private let workspace = UUID()
    private let high = SessionPriorityTarget(effort: .high)
    private let low = SessionPriorityTarget(effort: .low)

    /// Makes a restart of `pane` for `target` the way the drain does, ending in `.applied` 2 s
    /// after it started, so the session start is awaited until `nowMs + 62_000`.
    private func restart(
        _ state: inout SessionPriorityCoordinatorState,
        session: String = "s1",
        target: SessionPriorityTarget,
        atMs nowMs: Int64 = 0
    ) {
        let allowed = state.shouldAttempt(panelId: pane, sessionId: session, target: target)
        state.noteRestartStarted(panelId: pane, sessionId: session, target: target, nowMs: nowMs)
        let retry = state.noteResult(panelId: pane, .applied(sessionID: session), nowMs: nowMs + 2_000)
        #expect(allowed)
        #expect(retry == .none)
    }

    private func decide(
        _ state: inout SessionPriorityCoordinatorState,
        _ action: SessionPriorityPaneDecision.Action,
        session: String = "s1"
    ) -> SessionPriorityPaneState {
        state.noteDecision(action, panelId: pane, workspaceId: workspace, sessionId: session)
    }

    @Test
    func disablingDropsQueueAndRows() {
        var state = SessionPriorityCoordinatorState()
        state.queue.enqueue(panelId: pane, workspaceId: workspace, target: high)
        state.noteRestartStarted(panelId: UUID(), sessionId: "s2", target: low, nowMs: 0)
        state.rowsShown = [workspace, UUID()]
        let shown = state.rowsShown

        let clearRows = state.disable()

        #expect(clearRows == shown)
        #expect(state.queue.isEmpty)
        #expect(state.records.isEmpty)
        #expect(state.rowsShown.isEmpty)
    }

    @Test
    func heldResultArmsOneTimer() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)

        let firstRetry = state.noteResult(panelId: pane, .held(.draft), nowMs: 1_000)
        #expect(firstRetry == .timer(seconds: 30))
        #expect(state.records[pane]?.state == .held(.draft))
        #expect(state.records[pane]?.awaitingSessionStartUntilMs == nil)

        // Held again: one more 30 s timer, never a longer or second one, and a hold restarted
        // nothing, so the pane may still be tried for the same session and target.
        let mayRetry = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 31_000)
        let secondRetry = state.noteResult(panelId: pane, .held(.recentInput), nowMs: 31_500)
        let mayRetryAgain = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        #expect(mayRetry)
        #expect(secondRetry == .timer(seconds: 30))
        #expect(state.records[pane]?.state == .held(.recentInput))
        #expect(mayRetryAgain)
    }

    @Test
    func heldPaneWaitsForItsOwnRetry() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, .held(.draft), nowMs: 1_000)

        // The row refresh right after the hold, or another pane's turn end, does not retry it.
        let refreshed = decide(&state, .restart(high))
        #expect(refreshed == .held(.draft))
        #expect(state.queue.isEmpty)

        // Its timer fired, or its Claude ended a turn.
        state.noteRetryDue(panelId: pane)
        let retried = decide(&state, .restart(high))
        let queued = state.queue.next()
        #expect(retried == .held(.draft))
        #expect(queued?.target == high)
    }

    @Test
    func refusedPaneIsTriedAgainForANewTarget() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, .refused(.noConversationYet), nowMs: 500)

        _ = decide(&state, .restart(high))
        #expect(state.queue.isEmpty)

        _ = decide(&state, .restart(low))
        let queued = state.queue.next()
        #expect(queued?.target == low)
    }

    @Test
    func skippedEntryWaitsForItsRetry() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        _ = decide(&state, .restart(high))
        let drained = state.queue.next()

        // The drain could not reach the pane.
        state.noteSkipped(panelId: pane, target: high)
        let refreshed = decide(&state, .restart(high))

        #expect(drained?.panelId == pane)
        #expect(refreshed == .notApplied(nil))
        #expect(state.records[pane]?.lastResultDescription == "paneUnavailable")
        #expect(state.queue.isEmpty)
    }

    @Test
    func refusalSchedulesNoRetryTimer() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)

        let retry = state.noteResult(panelId: pane, .refused(.noConversationYet), nowMs: 500)

        #expect(retry == .none)
        #expect(state.records[pane]?.state == .notApplied(.noConversationYet))
        #expect(state.records[pane]?.awaitingSessionStartUntilMs == nil)
        #expect(state.records[pane]?.lastResultDescription == "refused.noConversationYet")
        // Nothing was restarted, so the next turn end may try again.
        let mayRetry = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        #expect(mayRetry)
    }

    @Test
    func sessionStartedForAnotherIdKeepsWaiting() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)

        let otherEnded = state.noteSessionStarted(panelId: pane, sessionId: "other")
        let stillWaiting = state.awaitsSessionStart(panelId: pane, nowMs: 10_000)
        #expect(!otherEnded)
        #expect(stillWaiting)
        #expect(state.records[pane]?.state == .applying)

        let ownEnded = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let waitingAfter = state.awaitsSessionStart(panelId: pane, nowMs: 10_000)
        #expect(ownEnded)
        #expect(!waitingAfter)
    }

    @Test
    func sessionEndedDropsStickyManual() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        let paneState = decide(&state, .leave(.manual(.userCommandOnScreen)))
        #expect(paneState == .manual(.userCommandOnScreen))
        #expect(state.records[pane]?.stickyManual == .userCommandOnScreen)

        state.noteSessionEnded(panelId: pane)

        #expect(state.records[pane]?.stickyManual == nil)
        #expect(state.records[pane] == nil)
    }

    @Test
    func applyingSurvivesUntilSessionStart() {
        var state = SessionPriorityCoordinatorState()
        let allowed = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        #expect(allowed)
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)

        // The replaced Claude's own end arrives while the restart runs.
        state.noteSessionEnded(panelId: pane)
        #expect(state.records[pane]?.state == .applying)

        let retry = state.noteResult(panelId: pane, .applied(sessionID: "s1"), nowMs: 5_000)
        #expect(retry == .none)
        #expect(state.records[pane]?.state == .applying)
        // A reconcile meanwhile, while the index still shows the old effort, keeps waiting.
        let paneState = decide(&state, .leave(.awaitingRestart))
        let waiting = state.awaitsSessionStart(panelId: pane, nowMs: 60_000)
        #expect(paneState == .applying)
        #expect(waiting)

        let ended = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let waitingAfter = state.awaitsSessionStart(panelId: pane, nowMs: 60_000)
        #expect(ended)
        #expect(!waitingAfter)
    }

    @Test
    func leavingAPaneDropsItsQueuedRestart() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        let queued = decide(&state, .restart(high))
        #expect(queued == .applying)
        #expect(!state.queue.isEmpty)

        let left = decide(&state, .leave(.upToDate))
        #expect(left == .upToDate)
        #expect(state.queue.isEmpty)
    }

    // MARK: - One restart per (session, target) (ruling R9)

    @Test
    func appliedTargetIsNotRetriedForTheSameSession() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        #expect(started)

        // The resumed session's recorded launch still lacks the effort: no second restart.
        let mayRetry = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        let paneState = decide(&state, .restart(high))
        #expect(!mayRetry)
        #expect(paneState == .notApplied(nil))
        #expect(state.records[pane]?.lastResultDescription == "targetNotRecorded")
        #expect(state.queue.isEmpty)
    }

    @Test
    func resumeNotTypedSpendsTheAttempt() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        let manual = ClaudeAccountSwitchManualResume(
            command: "claude --resume s1",
            typedInput: "claude --resume s1\n",
            paneWasReplaced: false
        )

        let retry = state.noteResult(panelId: pane, .resumeNotTyped(manual), nowMs: 4_000)
        let waiting = state.awaitsSessionStart(panelId: pane, nowMs: 4_000)
        // The pane was restarted: the user runs the resume, cmux does not restart it again.
        let mayRetry = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)

        #expect(retry == .none)
        #expect(state.records[pane]?.state == .notApplied(nil))
        #expect(!waiting)
        #expect(!mayRetry)
    }

    @Test
    func newTargetRearmsTheAttempt() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let mayRetrySame = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        #expect(started)
        #expect(!mayRetrySame)

        _ = decide(&state, .restart(low))

        let queued = state.queue.next()
        #expect(queued?.panelId == pane)
        #expect(queued?.target == low)
    }

    @Test
    func newSessionRearmsTheAttempt() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        #expect(started)

        // The user quits Claude and starts another session in the pane.
        state.noteSessionEnded(panelId: pane)
        state.follow(panelId: pane, sessionId: "s2")
        _ = decide(&state, .restart(high), session: "s2")

        let queued = state.queue.next()
        #expect(queued?.panelId == pane)
        #expect(queued?.target == high)
    }

    @Test
    func sessionStartTimeoutMarksNotApplied() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)

        let waitingBefore = state.awaitsSessionStart(panelId: pane, nowMs: 61_999)
        let waitingAtDeadline = state.awaitsSessionStart(panelId: pane, nowMs: 62_000)
        let mayRetry = state.shouldAttempt(panelId: pane, sessionId: "s1", target: high)
        // A start arriving after the deadline no longer ends a wait.
        let lateStartEnded = state.noteSessionStarted(panelId: pane, sessionId: "s1")

        #expect(waitingBefore)
        #expect(!waitingAtDeadline)
        #expect(state.records[pane]?.state == .notApplied(nil))
        #expect(state.records[pane]?.lastResultDescription == "sessionStartTimedOut")
        #expect(!mayRetry)
        #expect(!lateStartEnded)
    }

    // MARK: - Manual signals on screen

    @Test
    func adjustAutomaticallyIgnoresResultsAlreadyOnScreen() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        let seen = state.screenShowsManualMarker(panelId: pane, markerCount: 1)
        _ = decide(&state, .leave(.manual(.userCommandOnScreen)))

        state.clearStickyManual(panelIds: [pane], nowMs: 0)

        // The `/effort` result the user just dismissed is still on screen; once it scrolled
        // away, the next `/effort` is a new manual change.
        let dismissedStillShown = state.screenShowsManualMarker(panelId: pane, markerCount: 1)
        let scrolledAway = state.screenShowsManualMarker(panelId: pane, markerCount: 0)
        let typedAgain = state.screenShowsManualMarker(panelId: pane, markerCount: 1)
        #expect(seen)
        #expect(state.records[pane]?.stickyManual == nil)
        #expect(!dismissedStillShown)
        #expect(!scrolledAway)
        #expect(typedAgain)
    }

    @Test
    func resumedHistoryOnScreenIsNotAManualChange() {
        var state = SessionPriorityCoordinatorState()
        restart(&state, target: high)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")

        // The resumed Claude redraws an `/effort` result from earlier in the conversation; one
        // the user types now is new.
        let redrawn = state.screenShowsManualMarker(panelId: pane, markerCount: 1)
        let typedNow = state.screenShowsManualMarker(panelId: pane, markerCount: 2)
        #expect(started)
        #expect(!redrawn)
        #expect(typedNow)
    }

    /// A restart that replaced nothing leaves the user's own `/effort` on screen counting: it was
    /// typed while the pane waited in the queue or was held, not redrawn by a resumed Claude.
    @Test(arguments: [
        SessionPriorityApplyResult.held(.recentInput),
        .refused(.noConversationYet),
        .respawnFailed,
    ])
    func aRestartThatReplacedNothingKeepsTheUsersScreenChange(result: SessionPriorityApplyResult) {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, result, nowMs: 3_000)

        let usersEffortSeen = state.screenShowsManualMarker(panelId: pane, markerCount: 1)

        #expect(usersEffortSeen)
    }

    /// The gate's look before a restart: it sees the user's `/effort`, respects a dismissal,
    /// and leaves the dismissed count for the next screen read.
    @Test
    func gateLookSeesAUserChangeWithoutLoweringTheDismissedCount() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        #expect(state.showsUndismissedManualMarker(panelId: pane, markerCount: 1))

        state.clearStickyManual(panelIds: [pane], nowMs: 0)
        #expect(!state.showsUndismissedManualMarker(panelId: pane, markerCount: 1))
        #expect(!state.showsUndismissedManualMarker(panelId: pane, markerCount: 0))
        // Still dismissed after the look: the screen read, not the gate, lowers the count.
        #expect(state.records[pane]?.dismissedScreenMarkers == .max)
    }

    @Test
    func resumeNotTypedRedrawIsNotAManualChange() {
        var state = SessionPriorityCoordinatorState()
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        let manual = ClaudeAccountSwitchManualResume(
            command: "claude --resume s1",
            typedInput: "claude --resume s1\n",
            paneWasReplaced: false
        )
        _ = state.noteResult(panelId: pane, .resumeNotTyped(manual), nowMs: 4_000)

        // The user runs the resume by hand; that Claude redraws the conversation.
        let redrawn = state.screenShowsManualMarker(panelId: pane, markerCount: 1)
        let typedNow = state.screenShowsManualMarker(panelId: pane, markerCount: 2)
        #expect(!redrawn)
        #expect(typedNow)
    }

    @Test
    func screenMarkerCountCountsEachResult() {
        let screen = "Effort level set to low\n> hi\nModel set to opus\n> again\nEffort level set to high\n"
        #expect(SessionPriorityCoordinatorState.screenMarkerCount(in: screen) == 3)
        #expect(SessionPriorityCoordinatorState.screenMarkerCount(in: "> plain prompt") == 0)
    }
}
