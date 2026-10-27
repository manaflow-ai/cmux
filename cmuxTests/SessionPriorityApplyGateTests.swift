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

    @Test
    func holdsWhileResponding() {
        var facts = clearFacts()
        facts.responseRunning = true

        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.responding))
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
            accountSwitchInFlight: false
        )
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.responding))
        facts.responseRunning = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.recentInput))
        facts.receivedInputRecently = false
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.interruptHint))
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .draft, showsInterruptHint: false)
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.draft))
        facts.screen = ClaudeAccountAutoSwitchContinueGate.Screen(state: .emptyPrompt, showsInterruptHint: false)
        #expect(SessionPriorityApplyGate.evaluate(facts) == .hold(.notForeground))
    }

    @Test
    func quietInputWindowIsTenSeconds() {
        #expect(SessionPriorityApplyGate.quietInputWindow == .seconds(10))
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
