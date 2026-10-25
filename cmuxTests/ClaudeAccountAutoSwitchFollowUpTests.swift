import CMUXAgentLaunch
import CMUXMobileCore
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// After the switch: only a switch whose resume was typed may type `continue`, into the session
/// it resumed, and nothing that left the pane alone is announced.
struct ClaudeAccountAutoSwitchFollowUpTests {
    private let home = "/Users/cmux-test"
    private let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"

    @Test(arguments: [true, false])
    func aResumedSwitchIsAnnouncedAndContinuesOnlyWhenTrusted(sendContinue: Bool) throws {
        let result = ClaudeAccountSwitchResult.switched(try makePlan(), .copied)

        #expect(ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: sendContinue) == .announce(
            from: ClaudeAccountRegistry.defaultAccountName,
            to: "work",
            sessionId: sessionId,
            typeContinue: sendContinue
        ))
    }

    @Test(arguments: [true, false])
    func aSwitchWithoutResumeNeverTypes(sendContinue: Bool) throws {
        let manualResume = ClaudeAccountSwitchManualResume(
            command: "cd /Users/cmux-test/project && claude --resume s1",
            typedInput: "x\n",
            paneWasReplaced: false
        )
        let result = ClaudeAccountSwitchResult.switchedWithoutResume(try makePlan(), .copied, manualResume)

        #expect(ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: sendContinue) == .announceWithoutResume(
            from: ClaudeAccountRegistry.defaultAccountName,
            to: "work"
        ))
    }

    @Test
    func everyRefusalAndFailureKeepsTheUsageLimitStatus() {
        let results: [ClaudeAccountSwitchResult] = [
            .refused(.noClaudeSession),
            .refused(.missingWorkingDirectory),
            .refused(.unknownAccount("work")),
            .refused(.sameAccount("work")),
            .refused(.noConversationYet),
            .refused(.transcriptDiverged(newerAccount: "work")),
            .notClaude,
            .remoteUnsupported,
            .agentNotOwnedByPane,
            .alreadySwitching,
            .transcriptUnavailable,
            .respawnFailed,
        ]
        for result in results {
            #expect(ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: true) == .keepUsageLimitStatus, "\(result)")
        }
    }

    private func makePlan() throws -> ClaudeAccountSwitchPlan {
        try ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionId,
            workingDirectory: "\(home)/project",
            launchEnvironment: nil,
            targetName: "work",
            registry: ClaudeAccountRegistry(
                declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")],
                homeDirectory: home
            ),
            homeDirectory: home
        ).get()
    }
}

/// Spec D8: `continue` is typed only into the resumed Claude's own idle prompt.
@MainActor
struct ClaudeAccountAutoSwitchContinueGateTests {
    private typealias Gate = ClaudeAccountAutoSwitchContinueGate
    private let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
    private let idle = Gate.Screen(state: .emptyPrompt, showsInterruptHint: false)

    private func startedGate() -> Gate {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        return gate
    }

    private func step(
        _ gate: Gate,
        elapsed: Duration = .seconds(2),
        isEnabled: Bool = true,
        running: Bool = false,
        screen: Gate.Screen? = nil,
        foreground: Bool = true
    ) -> Gate.Step {
        gate.step(
            elapsed: elapsed,
            isEnabled: isEnabled,
            responseRunning: running,
            screen: { screen ?? idle },
            claudeInForeground: { foreground }
        )
    }

    @Test
    func aShellPromptBeforeClaudeStartsIsNeverTypedInto() {
        var screenReads = 0
        let step = Gate(sessionId: sessionId).step(
            elapsed: .seconds(1),
            isEnabled: true,
            responseRunning: false,
            screen: {
                screenReads += 1
                return idle
            },
            claudeInForeground: { true }
        )

        #expect(step == .wait)
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

        #expect(AgentAutoResumeCoordinator.screenState(in: frame) == .dialog)
        #expect(step(startedGate(), screen: Gate.Screen(frame: frame)) == .wait)
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

        #expect(reading.state == .emptyPrompt)
        #expect(reading.showsInterruptHint)
        #expect(step(startedGate(), screen: reading) != .send)
    }

    @Test
    func claudesIdlePromptAfterItsSessionStartGetsContinue() {
        #expect(step(startedGate()) == .send)
    }

    @Test
    func onlyTheResumedSessionsStartCounts() {
        // A `claude` the user started by hand, or a `/clear`, is another session.
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: "0f0e0d0c-0000-4000-8000-000000000001")

        #expect(step(gate) == .giveUp(.otherSession))
    }

    @Test
    func aClaudeThatDoesNotOwnTheTerminalIsNotTypedInto() {
        #expect(step(startedGate(), foreground: false) == .wait)
    }

    @Test
    func inputDuringTheWaitEndsIt() {
        var gate = startedGate()
        gate.userDidInput()

        #expect(step(gate) == .giveUp(.userInput))
    }

    @Test(arguments: [
        AgentAutoResumeCoordinator.ScreenState.unknown,
        .draft,
        .dialog,
        .codexGoalResume,
        .codexResumePicker,
    ])
    func anyOtherScreenWaits(screen: AgentAutoResumeCoordinator.ScreenState) {
        #expect(step(startedGate(), screen: Gate.Screen(state: screen, showsInterruptHint: false)) == .wait)
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

        #expect(step(gate) == .giveUp(.sessionBusy))
    }

    @Test
    func theReplacedClaudesSessionEndDoesNotCountButTheResumedOnesDoes() {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .sessionEnded, sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        #expect(step(gate) == .send)

        gate.observe(kind: .sessionEnded, sessionId: sessionId)
        #expect(step(gate) == .giveUp(.sessionEnded))
    }

    @Test
    func theStopFailuresOwnAttentionEchoDoesNotEndTheWait() {
        var gate = Gate(sessionId: sessionId)
        gate.observe(kind: .errorReported, sessionId: sessionId)
        gate.observe(kind: .sessionStarted, sessionId: sessionId)
        gate.observe(kind: .stateChanged, sessionId: sessionId)

        #expect(step(gate) == .send)
    }

    @Test
    func aRunningResponseEndsTheWait() {
        #expect(step(startedGate(), running: true) == .giveUp(.sessionBusy))
    }

    @Test
    func turningTheSettingOffEndsTheWait() {
        #expect(step(startedGate(), isEnabled: false) == .giveUp(.disabled))
    }

    @Test
    func theWaitEndsAfterOneMinute() {
        #expect(step(startedGate(), elapsed: .seconds(59), screen: Gate.Screen(state: .draft, showsInterruptHint: false)) == .wait)
        #expect(step(startedGate(), elapsed: .seconds(60)) == .giveUp(.timedOut))
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

/// The status and notification wording, compared with the same catalog lookups so the suite
/// holds in every locale.
struct ClaudeAccountAutoSwitchAnnouncementTests {
    private let now = Date(timeIntervalSince1970: 1_792_897_200)
    private let switchedTitle = String(localized: "notification.claudeAccountSwitch.title", defaultValue: "Claude account switched")

    @Test
    func theStatusNamesBothAccounts() {
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: nil, continues: true)

        #expect(announcement.statusText == String(
            format: String(
                localized: "sidebar.claudeAccountAutoSwitch.status",
                defaultValue: "Claude account: %1$@ → %2$@ (auto)"
            ),
            "default",
            "work"
        ))
        #expect(announcement.statusText.contains("default") && announcement.statusText.contains("work"))
    }

    @Test
    func theNotificationSaysTheConversationResumedAndQuotesTheReset() {
        let reset = now.addingTimeInterval(2 * 3600)
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: reset, continues: true)

        let notification = announcement.notification(now: now, calendar: seoulCalendar)

        #expect(notification.title == switchedTitle)
        #expect(notification.subtitle == announcement.statusText)
        #expect(notification.body == String(
            format: String(
                localized: "notification.claudeAccountAutoSwitch.resumed",
                defaultValue: "%1$@ hit its usage limit (resets %2$@). Resumed the conversation on %3$@."
            ),
            "default",
            ClaudeAccountAutoSwitchAnnouncement.resetText(reset, now: now, calendar: seoulCalendar),
            "work"
        ))
    }

    @Test
    func anUntrustedTargetAsksForFolderTrustFirst() {
        let reset = now.addingTimeInterval(2 * 3600)
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: reset, continues: false)

        #expect(announcement.notification(now: now, calendar: seoulCalendar).body == String(
            format: String(
                localized: "notification.claudeAccountAutoSwitch.confirmTrust",
                defaultValue: "%1$@ hit its usage limit (resets %2$@). Confirm folder trust in %3$@, then continue."
            ),
            "default",
            ClaudeAccountAutoSwitchAnnouncement.resetText(reset, now: now, calendar: seoulCalendar),
            "work"
        ))
    }

    @Test(arguments: [true, false])
    func aGuessedResetIsNeverShown(continues: Bool) {
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: nil, continues: continues)

        let expected = continues
            ? String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.resumedNoReset",
                    defaultValue: "%1$@ hit its usage limit. Resumed the conversation on %2$@."
                ),
                "default",
                "work"
            )
            : String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.confirmTrustNoReset",
                    defaultValue: "%1$@ hit its usage limit. Confirm folder trust in %2$@, then continue."
                ),
                "default",
                "work"
            )
        #expect(announcement.notification(now: now, calendar: seoulCalendar).body == expected)
    }

    @Test
    func aResetOnAnotherDayIncludesItsDate() {
        let sameDay = ClaudeAccountAutoSwitchAnnouncement.resetText(now.addingTimeInterval(3600), now: now, calendar: seoulCalendar)
        let nextWeek = ClaudeAccountAutoSwitchAnnouncement.resetText(now.addingTimeInterval(6 * 86_400), now: now, calendar: seoulCalendar)

        #expect(!sameDay.isEmpty)
        #expect(nextWeek.count > sameDay.count)
    }

    @Test
    func aContinueThatWasNotTypedSaysWhy() {
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: nil, continues: true)
        let inUse = String(
            format: String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.inUse",
                defaultValue: "cmux didn't type continue on %@: the terminal was in use."
            ),
            "work"
        )
        let expected: [(ClaudeAccountAutoSwitchContinueGate.GiveUpReason, String)] = [
            (.timedOut, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.timedOut",
                defaultValue: "cmux didn't type continue on %@: Claude didn't reach an empty prompt within a minute."
            ), "work")),
            (.sessionEnded, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.sessionEnded",
                defaultValue: "cmux didn't type continue on %@: the resumed Claude session ended."
            ), "work")),
            (.sessionBusy, inUse),
            (.otherSession, inUse),
            (.userInput, inUse),
            (.disabled, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.disabled",
                defaultValue: "cmux didn't type continue on %@: automatic account switching was turned off."
            ), "work")),
            (.paneGone, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.paneGone",
                defaultValue: "cmux didn't type continue on %@: the terminal was closed."
            ), "work")),
        ]
        for (reason, body) in expected {
            let notification = announcement.notContinuedNotification(reason: reason)
            #expect(notification.title == switchedTitle, "\(reason)")
            #expect(notification.subtitle == announcement.statusText, "\(reason)")
            #expect(notification.body == body, "\(reason)")
        }
    }

    @Test
    func aHeldBackSwitchSaysWhyAndHowToContinue() {
        let notSwitched = String(
            localized: "notification.claudeAccountAutoSwitch.notSwitched.title",
            defaultValue: "Claude account not switched"
        )
        let expected: [(ClaudeAccountAutoSwitchAction.HoldBack, String)] = [
            (.userInput, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.userInput",
                defaultValue: "%@ hit its usage limit, but the terminal was used afterwards, so cmux didn't switch accounts. Switch accounts manually to continue."
            ), "default")),
            (.backgroundWork, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.backgroundWork",
                defaultValue: "%@ hit its usage limit while background work was still running. Switching accounts restarts the terminal and would stop that work, so cmux didn't switch. Switch accounts manually when it's done."
            ), "default")),
            (.attemptLimit, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.attemptLimit",
                defaultValue: "%@ hit its usage limit. This terminal already went through every other account without finishing a turn, so cmux stopped switching it automatically."
            ), "default")),
            (.notRecorded, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.notRecorded",
                defaultValue: "%@ hit its usage limit, but cmux couldn't record that, so it didn't switch accounts automatically. Switch accounts manually to continue."
            ), "default")),
        ]
        var bodies = Set<String>()
        for (reason, body) in expected {
            let notification = ClaudeAccountAutoSwitchAnnouncement.holdBackNotification(from: "default", reason: reason)
            #expect(notification.title == notSwitched, "\(reason)")
            #expect(notification.body == body, "\(reason)")
            bodies.insert(notification.body)
        }
        #expect(bodies.count == expected.count)
    }

    private var seoulCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }
}
