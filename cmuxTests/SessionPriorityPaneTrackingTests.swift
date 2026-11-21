import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What the session priority coordinator keeps about a pane between the agent index's views of
/// it: a restarted pane until the index shows its resumed Claude, and background work its
/// Claude's last turn end reported.
///
/// `#expect` captures its operands, so each mutating call's result is bound first.
struct SessionPriorityPaneTrackingTests {
    private let pane = UUID()
    private let high = SessionPriorityTarget(effort: .high)

    /// Restarts `pane` for `high` the way the drain does: the restart replaced its Claude.
    private func restart(_ state: inout SessionPriorityCoordinatorState, session: String = "s1") {
        state.follow(panelId: pane, sessionId: session)
        state.noteRestartStarted(panelId: pane, sessionId: session, target: high, nowMs: 0)
        let retry = state.noteResult(panelId: pane, .applied(sessionID: session), nowMs: 2_000)
        #expect(retry == .none)
    }

    // MARK: - A restarted pane stays a Claude pane (E2E F2)

    /// The resumed Claude reports its start before the agent index has caught up with it. The
    /// pane still counts, so its workspace keeps its tier and the next one does not move up.
    @Test
    func restartedPaneCountsUntilTheIndexShowsItsResumedClaude() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        let whileWaiting = state.isRestarting(panelId: pane, nowMs: 3_000)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let beforeIndex = state.isRestarting(panelId: pane, nowMs: 3_000)

        // A reconcile reads the resumed Claude from the index.
        state.follow(panelId: pane, sessionId: "s1")
        let afterIndex = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(whileWaiting)
        #expect(started)
        #expect(beforeIndex)
        #expect(!afterIndex)
    }

    /// Before the resumed Claude's start, the index may still show the replaced one: seeing it
    /// does not end the restart.
    @Test
    func indexEntrySeenBeforeTheSessionStartDoesNotEndTheRestart() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        state.follow(panelId: pane, sessionId: "s1")
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let restarting = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(started)
        #expect(restarting)
    }

    @Test
    func restartedPaneStopsCountingWhenItsSessionEnds() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        _ = state.noteSessionStarted(panelId: pane, sessionId: "s1")

        state.noteSessionEnded(panelId: pane)
        let restarting = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(!restarting)
    }

    /// A restart that left a bare shell (the resume was not typed) has no Claude to wait for.
    @Test
    func restartThatLeftABareShellDoesNotCount() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        let manual = ClaudeAccountSwitchManualResume(
            command: "claude --resume s1",
            typedInput: "claude --resume s1\n",
            paneWasReplaced: false
        )
        _ = state.noteResult(panelId: pane, .resumeNotTyped(manual), nowMs: 1_000)
        let restarting = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(!restarting)
    }

    /// A resumed Claude that never reported its start leaves the pane not applied, and no
    /// longer a Claude pane until the index shows one.
    @Test
    func restartWhoseSessionNeverStartedStopsCountingAtTheDeadline() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        let deadline = 2_000 + SessionPriorityCoordinatorState.sessionStartTimeoutMs

        let waiting = state.awaitsSessionStart(panelId: pane, nowMs: deadline)
        let restarting = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(!waiting)
        #expect(!restarting)
        #expect(state.records[pane]?.state == .notApplied(nil))
    }

    /// A hold restarted nothing: the pane keeps its Claude and its index entry.
    @Test
    func heldAttemptDoesNotCountAsARestart() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, .held(.draft), nowMs: 1_000)
        let restarting = state.isRestarting(panelId: pane, nowMs: 3_000)

        #expect(!restarting)
    }

    /// A resumed Claude that died without a `SessionEnd` before the index saw it: a minute after
    /// its start the pane counts only by its index entry, so its workspace leaves the plan.
    @Test
    func restartedPaneStopsCountingAMinuteAfterItsStartWithoutAnIndexEntry() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1", occurredAtMs: 10_000)
        let limit = SessionPriorityCoordinatorState.indexAfterSessionStartTimeoutMs

        let justBefore = state.isRestarting(panelId: pane, nowMs: 10_000 + limit - 1)
        let atTheLimit = state.isRestarting(panelId: pane, nowMs: 10_000 + limit)

        #expect(started)
        #expect(limit == 60_000)
        #expect(justBefore)
        #expect(!atTheLimit)
    }

    /// `claude --resume` keeps the session id, so the replaced Claude's `SessionEnd` arriving after
    /// the resumed one's `SessionStart` looks like its own. It happened before that start, so it
    /// is ignored; the resumed Claude's own end still counts.
    @Test
    func replacedClaudesLateSessionEndDoesNotEndTheResumedOne() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        _ = state.noteSessionStarted(panelId: pane, sessionId: "s1", occurredAtMs: 10_000)

        state.noteSessionEnded(panelId: pane, occurredAtMs: 9_500)
        let afterLateEnd = state.isRestarting(panelId: pane, nowMs: 11_000)
        let sessionAfterLateEnd = state.records[pane]?.sessionId

        state.noteSessionEnded(panelId: pane, occurredAtMs: 12_000)
        let afterOwnEnd = state.isRestarting(panelId: pane, nowMs: 12_500)

        #expect(afterLateEnd)
        #expect(sessionAfterLateEnd == "s1")
        #expect(!afterOwnEnd)
    }

    // MARK: - Background work from the last turn end (E2E F3)

    /// A turn that ended with background work holds the pane until its next turn starts, also
    /// when a later hook (a `SubagentStop`) moved the sidebar lifecycle back to running.
    @Test
    func turnEndWithPendingWorkHoldsUntilTheNextTurnStarts() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)
        let pending = state.hasPendingBackgroundWork(panelId: pane)

        state.noteTurnStarted(panelId: pane)
        let afterTurnStart = state.hasPendingBackgroundWork(panelId: pane)

        #expect(pending)
        #expect(!afterTurnStart)
        #expect(state.lastTurnEndedAtMs[pane] == 1_000)
    }

    /// The idle prompt carries the last turn end's flag: while it still reports work the hold
    /// stays; without it, or at a turn end without it, the hold ends.
    @Test
    func turnEndOrIdlePromptWithoutPendingWorkEndsIt() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)
        state.noteTurnEnded(panelId: pane, nowMs: 61_000, pendingWork: true)
        let stillPending = state.hasPendingBackgroundWork(panelId: pane)

        state.noteTurnEnded(panelId: pane, nowMs: 62_000, pendingWork: false)
        let afterIdle = state.hasPendingBackgroundWork(panelId: pane)

        #expect(stillPending)
        #expect(!afterIdle)
    }

    @Test
    func sessionEndEndsIt() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)

        state.noteSessionEnded(panelId: pane)
        let pending = state.hasPendingBackgroundWork(panelId: pane)

        #expect(!pending)
    }

    /// Kept while off, like the turn end itself, so turning the feature on while the work runs
    /// still holds the pane.
    @Test
    func pendingWorkOutlivesTurningTheFeatureOff() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)

        _ = state.disable()
        let pending = state.hasPendingBackgroundWork(panelId: pane)

        #expect(pending)
    }

    @Test
    func closedPaneForgetsIt() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)

        state.retainPanes([])
        let pending = state.hasPendingBackgroundWork(panelId: pane)

        #expect(!pending)
    }

    // MARK: - Turned off where the coordinator could not see it (E2E O1)

    /// A `defaults write` from another process turns the feature off without a notification.
    /// The next trigger or status read that finds it off drops whatever the coordinator still
    /// shows or holds.
    @Test
    func rowsRecordsAndQueuedRestartsAreWhatTurningOffDrops() {
        var state = SessionPriorityCoordinatorState()
        let fresh = state.hasActiveState

        state.rowsShown = [UUID()]
        let withRows = state.hasActiveState
        _ = state.disable()
        let afterDisable = state.hasActiveState

        state.queue.enqueue(panelId: pane, workspaceId: UUID(), target: high)
        let withQueue = state.hasActiveState
        _ = state.disable()

        state.follow(panelId: pane, sessionId: "s1")
        let withRecord = state.hasActiveState
        _ = state.disable()

        _ = state.requestReconcile(nowMs: 0, settles: false)
        let withPendingPass = state.hasActiveState

        #expect(!fresh)
        #expect(withRows)
        #expect(!afterDisable)
        #expect(withQueue)
        #expect(withRecord)
        #expect(withPendingPass)
    }

    /// What the coordinator keeps while off on purpose does not count.
    @Test
    func turnEndsAndDismissalsKeptWhileOffAreNotDropped() {
        var state = SessionPriorityCoordinatorState()
        state.noteTurnEnded(panelId: pane, nowMs: 1_000, pendingWork: true)
        state.clearStickyManual(panelIds: [pane], nowMs: 1_000)

        let active = state.hasActiveState

        #expect(!active)
        #expect(state.lastTurnEndedAtMs[pane] == 1_000)
    }

    // MARK: - A pane left alone shows no stale hold (E2E O4)

    /// After a relaunch the pane was held for an undrawn screen, then its redrawn `/effort` made
    /// it manual: its detail is the manual signal, not the old hold.
    @Test
    func becomingManualClearsTheLastHold() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, .held(.unknownScreen), nowMs: 1_000)
        let heldDetail = state.records[pane]?.lastResultDescription

        let paneState = state.noteDecision(
            .leave(.manual(.userCommandOnScreen)),
            panelId: pane,
            workspaceId: UUID(),
            sessionId: "s1"
        )

        #expect(heldDetail == "held.unknownScreen")
        #expect(paneState == .manual(.userCommandOnScreen))
        #expect(state.records[pane]?.lastResultDescription == nil)
    }

    /// A `/effort` found in the transcript right before a restart makes the pane manual too.
    @Test
    func manualChangeInTheTranscriptClearsTheLastHold() {
        var state = SessionPriorityCoordinatorState()
        state.follow(panelId: pane, sessionId: "s1")
        state.noteRestartStarted(panelId: pane, sessionId: "s1", target: high, nowMs: 0)
        _ = state.noteResult(panelId: pane, .held(.draft), nowMs: 1_000)

        state.noteManualChangeInTranscript(panelId: pane)

        #expect(state.records[pane]?.state == .manual(.userCommandOnScreen))
        #expect(state.records[pane]?.lastResultDescription == nil)
    }
}
