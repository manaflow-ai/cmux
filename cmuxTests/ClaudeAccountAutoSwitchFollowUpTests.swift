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

/// After the switch: only a switch whose resume was typed may type `continue`, and nothing that
/// left the pane alone is announced.
struct ClaudeAccountAutoSwitchFollowUpTests {
    private let home = "/Users/cmux-test"

    @Test(arguments: [true, false])
    func aResumedSwitchIsAnnouncedAndContinuesOnlyWhenTrusted(sendContinue: Bool) throws {
        let result = ClaudeAccountSwitchResult.switched(try makePlan(), .copied)

        #expect(ClaudeAccountAutoSwitchFollowUp(result: result, sendContinue: sendContinue) == .announce(
            from: ClaudeAccountRegistry.defaultAccountName,
            to: "work",
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
            sessionID: "a22293b7-bcef-4707-8439-2f538c8517a4",
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

/// Spec D8: `continue` is typed only into Claude's own empty prompt.
@MainActor
struct ClaudeAccountAutoSwitchContinueGateTests {
    @Test
    func aShellPromptBeforeClaudeStartsIsNeverTypedInto() {
        let gate = ClaudeAccountAutoSwitchContinueGate()
        var screenReads = 0

        let step = gate.step(elapsed: .seconds(1), isEnabled: true, responseRunning: false) {
            screenReads += 1
            return .emptyPrompt
        }

        #expect(step == .wait)
        #expect(screenReads == 0)
    }

    @Test
    func aShellPromptReadsAsAnEmptyPromptOnScreen() throws {
        // Why the gate waits for Claude's SessionStart: the screen alone can't tell them apart.
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
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)
        #expect(gate.step(elapsed: .seconds(1), isEnabled: true, responseRunning: false) {
            AgentAutoResumeCoordinator.screenState(in: frame)
        } == .wait)
    }

    @Test
    func claudesEmptyPromptAfterItsSessionStartGetsContinue() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { .emptyPrompt } == .send)
    }

    @Test(arguments: [
        AgentAutoResumeCoordinator.ScreenState.unknown,
        .draft,
        .dialog,
        .codexGoalResume,
        .codexResumePicker,
    ])
    func anyOtherScreenWaits(screen: AgentAutoResumeCoordinator.ScreenState) {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { screen } == .wait)
    }

    @Test(arguments: [
        AgentJournalEventKind.turnStarted,
        .approvalRequested,
        .questionRequested,
        .planReviewRequested,
    ])
    func someoneElseDrivingTheSessionEndsTheWait(kind: AgentJournalEventKind) {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)
        gate.observe(kind: kind)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { .emptyPrompt }
            == .giveUp(.sessionBusy))
    }

    @Test
    func theReplacedClaudesSessionEndDoesNotCountButTheResumedOnesDoes() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionEnded)
        gate.observe(kind: .sessionStarted)
        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { .emptyPrompt } == .send)

        gate.observe(kind: .sessionEnded)
        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { .emptyPrompt }
            == .giveUp(.sessionEnded))
    }

    @Test
    func theStopFailuresOwnAttentionEchoDoesNotEndTheWait() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .errorReported)
        gate.observe(kind: .sessionStarted)
        gate.observe(kind: .stateChanged)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: false) { .emptyPrompt } == .send)
    }

    @Test
    func aRunningResponseEndsTheWait() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: true, responseRunning: true) { .emptyPrompt }
            == .giveUp(.sessionBusy))
    }

    @Test
    func turningTheSettingOffEndsTheWait() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)

        #expect(gate.step(elapsed: .seconds(2), isEnabled: false, responseRunning: false) { .emptyPrompt }
            == .giveUp(.disabled))
    }

    @Test
    func theWaitEndsAfterOneMinute() {
        var gate = ClaudeAccountAutoSwitchContinueGate()
        gate.observe(kind: .sessionStarted)

        #expect(gate.step(elapsed: .seconds(59), isEnabled: true, responseRunning: false) { .draft } == .wait)
        #expect(gate.step(elapsed: .seconds(60), isEnabled: true, responseRunning: false) { .emptyPrompt }
            == .giveUp(.timedOut))
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
    func theNotificationSharesTheSwitchTitleAndQuotesTheReset() {
        let reset = now.addingTimeInterval(2 * 3600)
        let calendar = seoulCalendar
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: reset, continues: true)

        let notification = announcement.notification(now: now, calendar: calendar)

        #expect(notification.title == String(
            localized: "notification.claudeAccountSwitch.title",
            defaultValue: "Claude account switched"
        ))
        #expect(notification.subtitle == announcement.statusText)
        let resetText = ClaudeAccountAutoSwitchAnnouncement.resetText(reset, now: now, calendar: calendar)
        #expect(notification.body == String(
            format: String(
                localized: "notification.claudeAccountAutoSwitch.continuing",
                defaultValue: "%1$@ hit its usage limit (resets %2$@). Continuing on %3$@."
            ),
            "default",
            resetText,
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
                    localized: "notification.claudeAccountAutoSwitch.continuingNoReset",
                    defaultValue: "%1$@ hit its usage limit. Continuing on %2$@."
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
        let calendar = seoulCalendar
        let sameDay = ClaudeAccountAutoSwitchAnnouncement.resetText(now.addingTimeInterval(3600), now: now, calendar: calendar)
        let nextWeek = ClaudeAccountAutoSwitchAnnouncement.resetText(now.addingTimeInterval(6 * 86_400), now: now, calendar: calendar)

        #expect(!sameDay.isEmpty)
        #expect(nextWeek.count > sameDay.count)
    }

    private var seoulCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }
}
