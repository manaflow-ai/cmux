import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A session priority restart runs unattended, so it proceeds only while the pane's Claude sits
/// at its empty input prompt between turns, nobody has typed lately, and no account switch owns
/// the pane. Anything else holds it with the first reason found.
struct SessionPriorityApplyGateTests {
    @Test
    func proceedsWhenAllClear() {
        #expect(SessionPriorityApplyGate.evaluate(clearFacts()) == .proceed)
    }

    @Test
    func holdsWhileAnAccountSwitchIsInFlight() {
        var facts = clearFacts()
        facts.accountSwitchInFlight = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.accountSwitchInFlight))
    }

    /// A `/effort` the user typed while the pane waited in the queue, longer ago than the quiet
    /// window, still keeps the restart from replacing their effort.
    @Test
    func holdsWhenTheUserChangedTheEffortOnScreen() {
        var facts = clearFacts()
        facts.screenShowsManualChange = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.manualChange))
    }

    /// A "Don't Adjust" made while the restart was being prepared wins over the queued target.
    @Test
    func holdsWhenTheWorkspaceBecameManual() {
        var facts = clearFacts()
        facts.workspaceMarkedManual = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.manualChange))
    }

    /// A rank or difficulty change made while the restart was being prepared would restart the
    /// pane for a stale target.
    @Test
    func holdsWhenTheTargetChanged() {
        var facts = clearFacts()
        facts.targetIsCurrent = false

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.targetChanged))
    }

    @Test
    func holdsWhileResponding() {
        var facts = clearFacts()
        facts.responseRunning = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.responding))
    }

    /// A turn that ended with background Bash commands, Monitors or async Agents still running:
    /// the restart would kill them.
    @Test
    func holdsWhileBackgroundWorkIsPending() {
        var facts = clearFacts()
        facts.backgroundWorkPending = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.backgroundWork))
    }

    /// A `SubagentStop` after the turn's `Stop` moves the sidebar lifecycle back to running while
    /// the background work still runs: the hold names the work, not a response.
    @Test
    func backgroundWorkOutranksARunningTurn() {
        var facts = clearFacts()
        facts.responseRunning = true
        facts.backgroundWorkPending = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.backgroundWork))
    }

    /// The pane the user is looking at keeps its Claude: their next keystrokes would land in
    /// the fresh shell.
    @Test
    func holdsTheFocusedPane() {
        var facts = clearFacts()
        facts.paneIsFocused = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.focused))
    }

    @Test
    func holdsAfterRecentInput() {
        var facts = clearFacts()
        facts.receivedInputRecently = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.recentInput))
    }

    @Test
    func holdsWhileTheInterruptHintShows() {
        var facts = clearFacts()
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .emptyPrompt, showsInterruptHint: true)

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.interruptHint))
    }

    @Test
    func holdsOnADraft() {
        var facts = clearFacts()
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .draft, showsInterruptHint: false)

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.draft))
    }

    @Test
    func holdsOnADialog() {
        var facts = clearFacts()
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .dialog, showsInterruptHint: false)

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.dialog))
    }

    @Test(arguments: [
        AgentAutoResumeCoordinator.ScreenState.unknown,
        .codexGoalResume,
        .codexResumePicker,
    ])
    func holdsOnAnUnknownScreen(_ state: AgentAutoResumeCoordinator.ScreenState) {
        var facts = clearFacts()
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: state, showsInterruptHint: false)

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.unknownScreen))
    }

    @Test
    func holdsWhenClaudeIsNotInTheForeground() {
        var facts = clearFacts()
        facts.claudeInForeground = false

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.notForeground))
    }

    @Test
    func accountSwitchWinsOverEverything() {
        let facts = SessionPriorityApplyGate.Facts(
            responseRunning: true,
            receivedInputRecently: true,
            screen: ClaudeAccountAutoSwitchContinueGate.Screen(state: .dialog, showsInterruptHint: true),
            claudeInForeground: false,
            accountSwitchInFlight: true
        )

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.accountSwitchInFlight))
    }

    @Test
    func checksFollowTheDocumentedOrder() {
        var facts = SessionPriorityApplyGate.Facts(
            responseRunning: true,
            receivedInputRecently: true,
            screen: ClaudeAccountAutoSwitchContinueGate.Screen(state: .draft, showsInterruptHint: true),
            claudeInForeground: false,
            accountSwitchInFlight: true,
            screenShowsManualChange: true,
            workspaceMarkedManual: true,
            targetIsCurrent: false,
            backgroundWorkPending: true,
            paneIsFocused: true
        )
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.accountSwitchInFlight))
        facts.accountSwitchInFlight = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.manualChange))
        facts.screenShowsManualChange = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.manualChange))
        facts.workspaceMarkedManual = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.targetChanged))
        facts.targetIsCurrent = true
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.backgroundWork))
        facts.backgroundWorkPending = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.responding))
        facts.responseRunning = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.recentInput))
        facts.receivedInputRecently = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.focused))
        facts.paneIsFocused = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.interruptHint))
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .draft, showsInterruptHint: false)
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.draft))
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .emptyPrompt, showsInterruptHint: false)
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.notForeground))
    }

    @Test
    func quietInputWindowIsTenSeconds() {
        #expect(SessionPriorityApplyGate.quietInputWindow == .seconds(10))
        #expect(SessionPriorityApplyGate.quietInputWindowMs == 10_000)
    }

    /// The quiet window runs from the later of the last input and the last turn end: for a long
    /// turn the last input was the prompt, minutes before the turn ended.
    @Test
    func quietWindowRunsFromTheLaterOfInputAndTurnEnd() {
        let turnEnd: Int64 = 1_000_000
        func inside(nowMs: Int64, inputMs: Int64?, turnEndMs: Int64?) -> Bool {
            // The input ledger's own test: input later than the given time.
            SessionPriorityApplyGate.isInsideQuietWindow(
                nowMs: nowMs,
                receivedInputAfter: { (inputMs ?? .min) > $0 },
                lastTurnEndMs: turnEndMs
            )
        }
        // The prompt went in five minutes before the turn ended.
        let prompt = turnEnd - 300_000
        #expect(inside(nowMs: turnEnd + 100, inputMs: prompt, turnEndMs: turnEnd))
        #expect(inside(nowMs: turnEnd + 9_999, inputMs: prompt, turnEndMs: turnEnd))
        #expect(!inside(nowMs: turnEnd + 10_000, inputMs: prompt, turnEndMs: turnEnd))
        // Input after the turn end restarts the window.
        #expect(inside(nowMs: turnEnd + 12_000, inputMs: turnEnd + 5_000, turnEndMs: turnEnd))
        #expect(!inside(nowMs: turnEnd + 15_000, inputMs: turnEnd + 5_000, turnEndMs: turnEnd))
        // Either alone.
        #expect(inside(nowMs: 5_000, inputMs: 1, turnEndMs: nil))
        #expect(!inside(nowMs: 10_001, inputMs: 1, turnEndMs: nil))
        #expect(!inside(nowMs: 50_000, inputMs: nil, turnEndMs: nil))
    }

    private func clearFacts() -> SessionPriorityApplyGate.Facts {
        SessionPriorityApplyGate.Facts(
            responseRunning: false,
            receivedInputRecently: false,
            screen: ClaudeAccountAutoSwitchContinueGate.Screen(state: .emptyPrompt, showsInterruptHint: false),
            claudeInForeground: true,
            accountSwitchInFlight: false
        )
    }
}
