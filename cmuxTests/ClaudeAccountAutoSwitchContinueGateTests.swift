import CMUXMobileCore
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Spec D8: `continue` is typed only into the resumed Claude's own idle prompt. The switch is
/// announced once that Claude settled (its `SessionStart` hook clears the pane's notifications),
/// or with the reason when the wait ends first, and never twice.
@MainActor
struct ClaudeAccountAutoSwitchContinueGateTests {
    private typealias Gate = ClaudeAccountAutoSwitchContinueGate
    private let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let idle = Gate.Screen(state: .emptyPrompt, showsInterruptHint: false)
    private let busyScreen = Gate.Screen(state: .draft, showsInterruptHint: false)

    private func startedGate() -> Gate {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        return gate
    }

    private func poll(
        _ gate: inout Gate,
        elapsed: Duration = .seconds(2),
        isEnabled: Bool = true,
        running: Bool = false,
        screen: Gate.Screen? = nil,
        foreground: Bool = true
    ) -> Gate.Poll {
        let reading = screen ?? idle
        return gate.poll(
            elapsed: elapsed,
            isEnabled: isEnabled,
            responseRunning: running,
            screen: { reading },
            claudeInForeground: { foreground }
        )
    }

    /// Polls until the gate settles and returns the second poll.
    private func settle(_ gate: inout Gate, screen: Gate.Screen? = nil) -> Gate.Poll {
        _ = poll(&gate, screen: screen)
        return poll(&gate, screen: screen)
    }

    // MARK: Typing

    @Test
    func aShellPromptBeforeClaudeStartsIsNeverTypedInto() {
        var gate = Gate(sessionId: sessionId)
        var screenReads = 0

        let result = gate.poll(
            elapsed: .seconds(1),
            isEnabled: true,
            responseRunning: false,
            screen: {
                screenReads += 1
                return idle
            },
            claudeInForeground: { true }
        )

        #expect(result == Gate.Poll(step: .wait, announce: false))
        #expect(screenReads == 0)
    }

    @Test
    func aShellPromptReadsAsAnEmptyPromptOnScreen() throws {
        // Why the gate waits for the resumed session's own start: the screen can't tell them apart.
        let frame = try screen(["~/project", "❯ "], cursorRow: 1)

        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .emptyPrompt)
    }

    @Test
    func claudesFolderTrustPromptIsADialog() throws {
        let frame = try screen([
            " Do you trust the files in this folder?",
            "",
            " /Users/cmux-test/fresh",
            "",
            " ❯ 1. Yes, proceed",
            "   2. No, exit",
            "",
            " Enter to confirm · Esc to exit",
        ], cursorRow: 4)
        var gate = startedGate()

        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .dialog)
        #expect(settle(&gate, screen: Gate.Screen(frame: frame)).step == .wait)
    }

    @Test
    func aRunningTurnIsNeverTakenForAnEmptyPrompt() throws {
        // Claude keeps its input box empty while it works; only the hint says it is busy.
        let frame = try screen([
            "> Remember the codeword.",
            "✻ Cogitating… (3s · ↑ 120 tokens · esc to interrupt)",
            "",
            "❯ ",
        ], cursorRow: 3)
        let reading = Gate.Screen(frame: frame)
        var gate = startedGate()

        #expect(reading.state == .emptyPrompt)
        #expect(reading.showsInterruptHint)
        #expect(settle(&gate, screen: reading).step != .send)
    }

    @Test
    func claudesIdlePromptGetsContinueOnceItSettledAndAfterTheAnnouncement() {
        var gate = startedGate()

        #expect(poll(&gate) == Gate.Poll(step: .wait, announce: false))
        #expect(poll(&gate) == Gate.Poll(step: .send, announce: true))
    }

    @Test
    func onlyTheResumedSessionsStartCounts() {
        // A `claude` the user started by hand, or a `/clear`, is another session.
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: "0f0e0d0c-0000-4000-8000-000000000001")

        #expect(poll(&gate).step == .giveUp(.otherSession))
    }

    @Test
    func aClaudeThatDoesNotOwnTheTerminalIsNotTypedInto() {
        var gate = startedGate()
        for _ in 0..<3 {
            #expect(poll(&gate, foreground: false) == Gate.Poll(step: .wait, announce: false))
        }
    }

    @Test
    func inputDuringTheWaitEndsIt() {
        var gate = startedGate()
        gate.userDidInput()

        #expect(poll(&gate).step == .giveUp(.userInput))
    }

    @Test(arguments: [
        AgentAutoResumeCoordinator.ScreenState.unknown,
        .draft,
        .dialog,
        .codexGoalResume,
        .codexResumePicker,
    ])
    func anyOtherScreenWaits(screen: AgentAutoResumeCoordinator.ScreenState) {
        var gate = startedGate()
        #expect(settle(&gate, screen: Gate.Screen(state: screen, showsInterruptHint: false)).step == .wait)
    }

    @Test(arguments: [
        AgentJournalEventKind.turnStarted,
        .approvalRequested,
        .questionRequested,
        .planReviewRequested,
    ])
    func someoneElseDrivingTheSessionEndsTheWait(kind: AgentJournalEventKind) {
        var gate = startedGate()
        gate.observe(kind: kind, sessionId: sessionId)

        #expect(poll(&gate).step == .giveUp(.sessionBusy))
    }

    @Test
    func theReplacedClaudesSessionEndDoesNotCountButTheResumedOnesDoes() {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionEnded, sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        _ = poll(&gate, screen: busyScreen)
        #expect(poll(&gate, screen: busyScreen).step == .wait)

        gate.observe(kind: .sessionEnded, sessionId: sessionId)
        #expect(poll(&gate).step == .giveUp(.sessionEnded))
    }

    @Test
    func theStopFailuresOwnAttentionEchoDoesNotEndTheWait() {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .errorReported, sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        gate.observe(kind: .stateChanged, sessionId: sessionId)

        #expect(settle(&gate).step == .send)
    }

    @Test
    func aRunningResponseEndsTheWait() {
        var gate = startedGate()
        #expect(poll(&gate, running: true).step == .giveUp(.sessionBusy))
    }

    @Test
    func turningTheSettingOffEndsTheWait() {
        var gate = startedGate()
        #expect(poll(&gate, isEnabled: false).step == .giveUp(.disabled))
    }

    @Test
    func theWaitEndsAfterOneMinute() {
        var gate = startedGate()
        #expect(poll(&gate, elapsed: .seconds(59), screen: busyScreen).step == .wait)
        #expect(poll(&gate, elapsed: .seconds(60)).step == .giveUp(.timedOut))
    }

    // MARK: Announcing

    @Test
    func theSwitchIsAnnouncedOnceTheResumedClaudeSettledEvenWithoutContinue() {
        // The resumed session's SessionStart clears the pane's notifications right after it
        // registers Claude, so the announcement waits one full poll past that.
        var gate = startedGate()

        #expect(poll(&gate, screen: busyScreen) == Gate.Poll(step: .wait, announce: false))
        #expect(poll(&gate, screen: busyScreen) == Gate.Poll(step: .wait, announce: true))
        #expect(poll(&gate, screen: busyScreen) == Gate.Poll(step: .wait, announce: false))
        #expect(poll(&gate) == Gate.Poll(step: .send, announce: false))
    }

    @Test
    func aStartedSessionThatNeverSettlesIsAnnouncedWhenTheWaitEnds() {
        var gate = startedGate()
        _ = poll(&gate, foreground: false)
        _ = poll(&gate, foreground: false)

        #expect(poll(&gate, elapsed: .seconds(60)) == Gate.Poll(step: .giveUp(.timedOut), announce: true))
        #expect(poll(&gate, elapsed: .seconds(61)) == Gate.Poll(step: .giveUp(.timedOut), announce: false))
    }

    @Test(arguments: [
        ClaudeAccountAutoSwitchContinueGate.GiveUpReason.timedOut,
        .sessionEnded,
        .sessionBusy,
        .otherSession,
        .userInput,
        .disabled,
    ])
    func everyGiveUpBeforeTheAnnouncementCarriesItOnce(reason: ClaudeAccountAutoSwitchContinueGate.GiveUpReason) {
        var gate = Gate(sessionId: sessionId)
        var elapsed: Duration = .seconds(2)
        var isEnabled = true
        switch reason {
        case .timedOut:
            elapsed = .seconds(60)
        case .sessionEnded:
            gate.observe(kind: .sessionStarted, sessionId: sessionId)
            gate.observe(kind: .sessionEnded, sessionId: sessionId)
        case .sessionBusy:
            gate.observe(kind: .turnStarted, sessionId: sessionId)
        case .otherSession:
            gate.observe(kind: .sessionStarted, sessionId: "0f0e0d0c-0000-4000-8000-000000000001")
        case .userInput:
            gate.userDidInput()
        case .disabled:
            isEnabled = false
        case .paneGone:
            Issue.record("the coordinator ends a wait for a gone pane itself")
        }

        #expect(poll(&gate, elapsed: elapsed, isEnabled: isEnabled) == Gate.Poll(step: .giveUp(reason), announce: true))
        #expect(poll(&gate, elapsed: elapsed, isEnabled: isEnabled) == Gate.Poll(step: .giveUp(reason), announce: false))
        let owedAfterwards = gate.announceIfOwed()
        #expect(!owedAfterwards)
    }

    @Test
    func aGiveUpAfterTheAnnouncementDoesNotRepeatIt() {
        var gate = startedGate()
        _ = settle(&gate, screen: busyScreen)
        gate.userDidInput()

        #expect(poll(&gate) == Gate.Poll(step: .giveUp(.userInput), announce: false))
    }

    @Test
    func aWaitTheCoordinatorEndsAnnouncesOnlyWhatIsOwed() {
        // A gone pane, or a newer report replacing the wait.
        var owed = Gate(sessionId: sessionId)
        let first = owed.announceIfOwed()
        let second = owed.announceIfOwed()
        #expect(first)
        #expect(!second)

        var announced = startedGate()
        _ = settle(&announced, screen: busyScreen)
        let afterSettling = announced.announceIfOwed()
        #expect(!afterSettling)
    }

    private func screen(_ lines: [String], cursorRow: Int?) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "claude-account-auto-switch-test",
            stateSeq: 0,
            columns: 120,
            rows: lines.count,
            text: lines.joined(separator: "\n"),
            cursor: cursorRow.map { .init(row: $0, column: 3) }
        )
    }
}
