import CMUXAgentLaunch
import CMUXMobileCore
import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The automatic switch runs unattended, so a free account is not enough: it never restarts a
/// terminal that someone is using or that holds background work, it never cycles accounts
/// without end, and it never charges a late report to the account the pane runs now.
struct ClaudeAccountAutoSwitchHoldBackTests {
    private let fixture = ClaudeAccountAutoSwitchFixture()

    @Test
    func turningTheSettingOffDuringTheTrustReadMarksNothing() {
        #expect(fixture.decide(fixture.request(), pane: fixture.pane(), isEnabled: false) == .ignore)
    }

    @Test
    func aPaneAlreadySwitchingIsLeftAlone() {
        #expect(fixture.decide(fixture.request(), pane: .switching) == .ignore)
    }

    @Test
    func aReportFromBeforeThePanesLastSwitchIsIgnored() {
        var ledger = ClaudeAccountAutoSwitchLedger()
        ledger.noteAutomaticSwitch(panelId: fixture.panelId, atMs: fixture.nowMs + 1)
        #expect(fixture.decide(fixture.request(), pane: fixture.pane(current: "work"), ledger: ledger) == .ignore)

        var earlier = ClaudeAccountAutoSwitchLedger()
        earlier.noteAutomaticSwitch(panelId: fixture.panelId, atMs: fixture.nowMs - 1)
        #expect(fixture.decide(fixture.request(), pane: fixture.pane(current: "work"), ledger: earlier).exhaustion != nil)
    }

    @Test
    func aLateReportLeavesAWaitingContinueAlone() {
        // The replaced Claude's report, delivered after the switch, must not cancel the
        // `continue` the resumed Claude is waiting for.
        var ledger = ClaudeAccountAutoSwitchLedger()
        ledger.noteAutomaticSwitch(panelId: fixture.panelId, atMs: fixture.nowMs + 1)
        let late = fixture.decide(fixture.request(), pane: fixture.pane(current: "work"), ledger: ledger)

        #expect(late == .ignore)
        #expect(!late.supersedesPendingContinue)
        #expect(fixture.decide(fixture.request(), pane: fixture.pane()).supersedesPendingContinue)
        #expect(fixture.decide(
            fixture.request(),
            pane: fixture.pane(),
            stored: [fixture.workKey: fixture.now.addingTimeInterval(3600)]
        ).supersedesPendingContinue)
    }

    @Test
    func backgroundWorkHoldsTheSwitchBack() {
        let action = fixture.decide(fixture.request(pendingWork: true), pane: fixture.pane())

        guard case .holdBack(let exhaustion, .backgroundWork) = action else {
            Issue.record("expected a hold-back for background work, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == fixture.defaultKey)
    }

    @Test
    func inputAfterTheLimitHoldsTheSwitchBack() {
        var typedAfter = ClaudeAccountAutoSwitchLedger()
        typedAfter.noteInput(panelId: fixture.panelId, atMs: fixture.nowMs + 5)
        guard case .holdBack(_, .userInput) = fixture.decide(fixture.request(), pane: fixture.pane(), ledger: typedAfter) else {
            Issue.record("input after the limit must hold the switch back")
            return
        }

        var typedBefore = ClaudeAccountAutoSwitchLedger()
        typedBefore.noteInput(panelId: fixture.panelId, atMs: fixture.nowMs - 5)
        guard case .switchAccount = fixture.decide(fixture.request(), pane: fixture.pane(), ledger: typedBefore) else {
            Issue.record("input before the limit is the prompt that hit it")
            return
        }
    }

    @Test
    func aMessageTypedInClaudesInputHoldsTheSwitchBack() {
        // A draft typed during the failing turn stays in Claude's input box; the restart would
        // discard it and `continue` would replace it.
        guard case .holdBack(_, .draftPending) = fixture.decide(fixture.request(), pane: fixture.pane(), sourceScreen: .draft) else {
            Issue.record("a typed draft must hold the switch back")
            return
        }
        guard case .switchAccount = fixture.decide(fixture.request(), pane: fixture.pane(), sourceScreen: .emptyPrompt) else {
            Issue.record("an empty input box is no reason to stay")
            return
        }
    }

    @Test
    @MainActor
    func aDraftWrappedPastOneRowHoldsTheSwitchBack() throws {
        // Any sentence wider than a narrow split pane wraps, leaving the cursor on a
        // continuation row; the restart would discard it all the same.
        let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
            surfaceID: "claude-account-auto-switch-test",
            stateSeq: 0,
            columns: 40,
            rows: 3,
            text: ["❯ please also rename the helper and", "  update its tests", "────────────────────────"]
                .joined(separator: "\n"),
            cursor: .init(row: 1, column: 18)
        )
        let screen = AgentAutoResumeCoordinator.screenState(in: frame)

        guard case .holdBack(_, .draftPending) = fixture.decide(fixture.request(), pane: fixture.pane(), sourceScreen: screen) else {
            Issue.record("a wrapped draft must hold the switch back, screen read as \(screen)")
            return
        }
    }

    @Test
    func thePaneIsInUseWhenItHoldsADraftOrGotInput() {
        typealias HoldBack = ClaudeAccountAutoSwitchAction.HoldBack
        // The same check runs again, synchronously, right before the pane restarts.
        #expect(HoldBack.paneInUse(receivedInputSinceReport: false, screen: .emptyPrompt) == nil)
        #expect(HoldBack.paneInUse(receivedInputSinceReport: false, screen: .unknown) == nil)
        #expect(HoldBack.paneInUse(receivedInputSinceReport: false, screen: .draft) == .draftPending)
        #expect(HoldBack.paneInUse(receivedInputSinceReport: true, screen: .emptyPrompt) == .userInput)
        #expect(HoldBack.paneInUse(receivedInputSinceReport: true, screen: .draft) == .draftPending)
    }

    @Test
    func aHoldBackNeedsAFreeAccount() {
        // With nowhere to go, the pane just keeps its usage-limit status; no "switch manually".
        let action = fixture.decide(
            fixture.request(pendingWork: true),
            pane: fixture.pane(),
            stored: [fixture.workKey: fixture.now.addingTimeInterval(3600)]
        )
        guard case .markExhaustedOnly = action else {
            Issue.record("expected only a mark, got \(action)")
            return
        }
    }

    @Test
    func switchingStopsOnceEveryOtherAccountWasTriedWithoutAFinishedTurn() {
        let registry = fixture.registry(extra: [ClaudeAccountDeclaration(name: "spare", configDir: "~/.claude-spare")])
        var ledger = ClaudeAccountAutoSwitchLedger()
        ledger.noteAutomaticSwitch(panelId: fixture.panelId, atMs: fixture.nowMs - 2_000)
        guard case .switchAccount = fixture.decide(fixture.request(), pane: fixture.pane(registry: registry), ledger: ledger) else {
            Issue.record("one switch of two allowed is not the cap")
            return
        }

        ledger.noteAutomaticSwitch(panelId: fixture.panelId, atMs: fixture.nowMs - 1_000)
        guard case .holdBack(_, .attemptLimit) = fixture.decide(fixture.request(), pane: fixture.pane(registry: registry), ledger: ledger) else {
            Issue.record("two switches with three accounts is the cap")
            return
        }

        ledger.noteTurnCompleted(panelId: fixture.panelId)
        guard case .switchAccount = fixture.decide(fixture.request(), pane: fixture.pane(registry: registry), ledger: ledger) else {
            Issue.record("a finished turn resets the count")
            return
        }
    }

    @Test
    func aSourceThatCouldNotBeRecordedIsNotSwitchedAway() throws {
        // Otherwise the new account's limit would find the old one free and switch back, forever.
        let action = fixture.decide(fixture.request(), pane: fixture.pane())
        let exhaustion = try #require(action.exhaustion)

        #expect(action.recording(succeeded: false) == .holdBack(exhaustion, .notRecorded))
        #expect(action.recording(succeeded: true) == action)
        #expect(ClaudeAccountAutoSwitchAction.markExhaustedOnly(exhaustion).recording(succeeded: false)
            == .markExhaustedOnly(exhaustion))
        #expect(ClaudeAccountAutoSwitchAction.ignore.recording(succeeded: false) == .ignore)
    }

    @Test
    func aRememberedLimitCountsWhenTheFileReadsEmpty() {
        // default hit its limit and was switched away from; the file write was lost.
        var ledger = ClaudeAccountAutoSwitchLedger()
        ledger.recordExhaustion(accountKey: fixture.defaultKey, until: fixture.now.addingTimeInterval(3600))

        let action = fixture.decide(fixture.request(eventId: "event-2"), pane: fixture.pane(current: "work"), stored: [:], ledger: ledger)

        guard case .markExhaustedOnly(let exhaustion) = action else {
            Issue.record("must not switch back to the remembered account, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == fixture.workKey)
    }
}

/// What the coordinator remembers between reports.
struct ClaudeAccountAutoSwitchLedgerTests {
    private let panelId = UUID()
    private let now = Date(timeIntervalSince1970: 1_792_897_200)

    @Test
    func rememberedAndStoredExhaustionMergeUntilTheyReset() {
        var ledger = ClaudeAccountAutoSwitchLedger()
        ledger.recordExhaustion(accountKey: "/a", until: now.addingTimeInterval(60))
        ledger.recordExhaustion(accountKey: "/old", until: now.addingTimeInterval(-60))

        #expect(ledger.exhaustedKeys(stored: ["/b": now.addingTimeInterval(60)], now: now) == ["/a", "/b"])
    }

    @Test
    func inputCountsOnlyAfterTheGivenTime() {
        var ledger = ClaudeAccountAutoSwitchLedger()
        #expect(!ledger.receivedInput(panelId: panelId, after: 100))
        ledger.noteInput(panelId: panelId, atMs: 150)
        #expect(ledger.receivedInput(panelId: panelId, after: 100))
        #expect(!ledger.receivedInput(panelId: panelId, after: 150))
        #expect(!ledger.receivedInput(panelId: UUID(), after: 0))
    }

    @Test
    func switchesCountUntilATurnFinishes() {
        var ledger = ClaudeAccountAutoSwitchLedger()
        #expect(!ledger.tracksSwitches)
        ledger.noteAutomaticSwitch(panelId: panelId, atMs: 10)
        ledger.noteAutomaticSwitch(panelId: panelId, atMs: 20)

        #expect(ledger.tracksSwitches)
        #expect(ledger.automaticSwitches(panelId: panelId) == 2)
        #expect(ledger.lastAutomaticSwitchAtMs(panelId: panelId) == 20)

        ledger.noteTurnCompleted(panelId: panelId)
        #expect(ledger.automaticSwitches(panelId: panelId) == 0)
        #expect(!ledger.tracksSwitches)
        // The last switch time still rejects late reports from the replaced Claude.
        #expect(ledger.lastAutomaticSwitchAtMs(panelId: panelId) == 20)
    }
}

/// Spec D8: `continue` needs the resumed Claude to own the terminal at that moment.
struct ClaudeAccountAutoSwitchForegroundCheckTests {
    private let switchStartedAt = Date(timeIntervalSince1970: 1_000)
    private let paneTTY: Int64 = 0x1000_0007
    private let claude = AgentPIDProcessIdentity(pid: 4_242, startSeconds: 1_005, startMicroseconds: 0)

    private func facts(
        identity: AgentPIDProcessIdentity? = nil,
        tty: Int64? = nil,
        group: pid_t = 4_242,
        foreground: pid_t = 4_242
    ) -> ClaudeAccountAutoSwitchForegroundCheck.ProcessFacts {
        .init(identity: identity ?? claude, ttyDevice: tty ?? paneTTY, processGroup: group, terminalForegroundProcessGroup: foreground)
    }

    private func owns(
        registered: [AgentPIDProcessIdentity]? = nil,
        paneTTY: Int64?? = .none,
        facts: ClaudeAccountAutoSwitchForegroundCheck.ProcessFacts?
    ) -> Bool {
        ClaudeAccountAutoSwitchForegroundCheck.claudeOwnsTerminal(
            registered: registered ?? [claude],
            startedAfter: switchStartedAt,
            paneTTYDevice: paneTTY ?? self.paneTTY,
            facts: { _ in facts }
        )
    }

    @Test
    func theResumedClaudeInTheForegroundOwnsTheTerminal() {
        #expect(owns(facts: facts()))
    }

    @Test
    func aClaudeThatExitedOrWasReplacedDoesNot() {
        #expect(!owns(facts: nil))
        let reused = AgentPIDProcessIdentity(pid: 4_242, startSeconds: 1_100, startMicroseconds: 0)
        #expect(!owns(facts: facts(identity: reused)))
    }

    @Test
    func aClaudeInTheBackgroundOrOnAnotherTerminalDoesNot() {
        // The shell (or a job it started) holds the foreground: typing would reach it.
        #expect(!owns(facts: facts(foreground: 4_100)))
        #expect(!owns(facts: facts(tty: 0x1000_0009)))
        #expect(!owns(paneTTY: .some(nil), facts: facts()))
    }

    @Test
    func theReplacedClaudeDoesNotCount() {
        let replaced = AgentPIDProcessIdentity(pid: 4_242, startSeconds: 900, startMicroseconds: 0)
        #expect(!owns(registered: [replaced], facts: facts(identity: replaced)))
        #expect(!owns(registered: [], facts: facts()))
    }
}

/// The automatic switch types its resume command only into an untouched shell line.
@MainActor
struct ClaudeAccountSwitchShellLineTests {
    @Test(arguments: [AgentAutoResumeCoordinator.ScreenState.emptyPrompt, .unknown])
    func anUntouchedPromptTakesTheResume(screen: AgentAutoResumeCoordinator.ScreenState) {
        #expect(ClaudeAccountSwitchShellLine.acceptsResumeInput(receivedInputSinceRespawn: false, screen: screen))
    }

    @Test
    func anyInputSinceTheRespawnBlocksIt() {
        // A custom prompt reads as .unknown, so typeahead after it is only visible as input.
        #expect(!ClaudeAccountSwitchShellLine.acceptsResumeInput(receivedInputSinceRespawn: true, screen: .unknown))
        #expect(!ClaudeAccountSwitchShellLine.acceptsResumeInput(receivedInputSinceRespawn: true, screen: .emptyPrompt))
    }

    @Test(arguments: [AgentAutoResumeCoordinator.ScreenState.draft, .dialog])
    func aLineHoldingTextOrADialogBlocksIt(screen: AgentAutoResumeCoordinator.ScreenState) {
        #expect(!ClaudeAccountSwitchShellLine.acceptsResumeInput(receivedInputSinceRespawn: false, screen: screen))
    }
}

/// The automatic switch resolves its target in the user-level config both when it chooses an
/// account and when it plans the switch, so a project `.cmux/cmux.json` that redefines one of the
/// user's accounts can't redirect it into a directory the repository controls.
struct ClaudeAccountSwitchTriggerRegistryTests {
    @Test
    func anAutomaticSwitchPlansAgainstTheUserAccountsOnly() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("acct-trigger-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }
        let home = root + "/home"
        let project = root + "/project"
        let redirected = project + "/.x"
        try fm.createDirectory(atPath: home + "/.config/cmux", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/.cmux", withIntermediateDirectories: true)
        try #"{"agents":{"claudeAccounts":[{"name":"work","configDir":"~/.claude-work"}]}}"#
            .write(toFile: home + "/.config/cmux/cmux.json", atomically: true, encoding: .utf8)
        try """
        {"agents":{"claudeAccounts":[{"name":"work","configDir":"\(redirected)"},{"name":"rogue","configDir":"\(project)/.rogue"}]}}
        """.write(toFile: project + "/.cmux/cmux.json", atomically: true, encoding: .utf8)

        func plan(_ trigger: ClaudeAccountSwitchTrigger, to name: String) -> Result<ClaudeAccountSwitchPlan, ClaudeAccountSwitchRefusal> {
            trigger.plan(
                sessionID: "a22293b7-bcef-4707-8439-2f538c8517a4",
                workingDirectory: project,
                launchEnvironment: nil,
                targetName: name,
                homeDirectory: home,
                paneWorkingDirectory: project
            )
        }

        let automatic = try plan(.automatic, to: "work").get()
        #expect(automatic.targetConfigDirectory.hasSuffix("/home/.claude-work"), "\(automatic.targetConfigDirectory)")
        #expect(automatic.surfaceEnvironmentOverrides["CLAUDE_CONFIG_DIR"] == automatic.targetConfigDirectory)
        #expect(plan(.automatic, to: "rogue") == .failure(.unknownAccount("rogue")))
        // Planning resolves names only; nothing appears under the project.
        #expect(!fm.fileExists(atPath: redirected))
        #expect(!fm.fileExists(atPath: project + "/.rogue"))

        // A manual switch keeps the merged registry, where the project entry replaces the user's.
        let manual = try plan(.manual, to: "work").get()
        #expect(manual.targetConfigDirectory.hasSuffix("/project/.x"), "\(manual.targetConfigDirectory)")
    }
}
