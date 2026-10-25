import CMUXAgentLaunch
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

    @Test
    func aPaneInUseRightBeforeTheRestartIsHeldBackNotIgnored() {
        #expect(ClaudeAccountAutoSwitchFollowUp(result: .paneInUse, sendContinue: true) == .paneInUse)
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
            let notification = announcement.notContinuedNotification(
                reason: reason,
                includingSwitch: false,
                now: now,
                calendar: seoulCalendar
            )
            #expect(notification.title == switchedTitle, "\(reason)")
            #expect(notification.subtitle == announcement.statusText, "\(reason)")
            #expect(notification.body == body, "\(reason)")
        }
    }

    @Test
    func aWaitThatEndsBeforeTheAnnouncementAlsoSaysTheSwitchHappened() {
        // One notification: a second one on the same pane would replace the first.
        let reset = now.addingTimeInterval(2 * 3600)
        let announcement = ClaudeAccountAutoSwitchAnnouncement(from: "default", to: "work", reset: reset, continues: true)
        let switched = announcement.notification(now: now, calendar: seoulCalendar)
        let reasonOnly = announcement.notContinuedNotification(
            reason: .timedOut,
            includingSwitch: false,
            now: now,
            calendar: seoulCalendar
        )

        let combined = announcement.notContinuedNotification(
            reason: .timedOut,
            includingSwitch: true,
            now: now,
            calendar: seoulCalendar
        )

        #expect(combined.title == switchedTitle)
        #expect(combined.subtitle == announcement.statusText)
        #expect(combined.body == switched.body + "\n" + reasonOnly.body)
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
            (.draftPending, String(format: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.draftPending",
                defaultValue: "%@ hit its usage limit while a message was typed in Claude's input box. Switching accounts restarts the terminal and would discard it, so cmux didn't switch. Switch accounts manually to continue."
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
