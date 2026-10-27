import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What the session priority coordinator keeps about a pane between the agent index's views of
/// it: a restarted pane until the index shows its resumed Claude.
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
        let whileWaiting = state.isRestarting(panelId: pane)
        let started = state.noteSessionStarted(panelId: pane, sessionId: "s1")
        let beforeIndex = state.isRestarting(panelId: pane)

        // A reconcile reads the resumed Claude from the index.
        state.follow(panelId: pane, sessionId: "s1")
        let afterIndex = state.isRestarting(panelId: pane)

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
        let restarting = state.isRestarting(panelId: pane)

        #expect(started)
        #expect(restarting)
    }

    @Test
    func restartedPaneStopsCountingWhenItsSessionEnds() {
        var state = SessionPriorityCoordinatorState()
        restart(&state)
        _ = state.noteSessionStarted(panelId: pane, sessionId: "s1")

        state.noteSessionEnded(panelId: pane)
        let restarting = state.isRestarting(panelId: pane)

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
        let restarting = state.isRestarting(panelId: pane)

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
        let restarting = state.isRestarting(panelId: pane)

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
        let restarting = state.isRestarting(panelId: pane)

        #expect(!restarting)
    }
}
