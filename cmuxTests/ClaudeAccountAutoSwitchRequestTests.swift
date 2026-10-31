import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The automatic Claude account switch decides in pure steps: which journal events count as a
/// usage limit, what to do about one, what to do after the switch, and when `continue` may be
/// typed. The coordinator only runs them.
struct ClaudeAccountAutoSwitchRequestTests {
    private let fixture = ClaudeAccountAutoSwitchFixture()

    // MARK: Which events count

    @Test
    func theStopFailureUsageLimitEventIsARequest() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: fixture.draft(pendingWork: true), isEnabled: true))

        #expect(request.workspaceId == fixture.workspaceId)
        #expect(request.panelId == fixture.panelId)
        #expect(request.detail == "usage_limit: \(fixture.seoulMessage)")
        #expect(request.eventId == "event-1")
        #expect(request.occurredAtMs == fixture.nowMs)
        #expect(request.pendingWork)
    }

    @Test
    func nothingHappensWhileTheSettingIsOff() {
        #expect(ClaudeAccountAutoSwitchRequest(draft: fixture.draft(), isEnabled: false) == nil)
    }

    @Test
    func otherEventsNeverReadTheSetting() {
        // Every journal event passes through; only a usage-limit report may read the defaults.
        var reads = 0
        func enabled() -> Bool {
            reads += 1
            return true
        }
        let drafts = [
            fixture.draft(kind: .turnCompleted),
            fixture.draft(detail: "rate_limit: Rate limited"),
            fixture.draft(source: "codex"),
        ]
        for draft in drafts {
            #expect(ClaudeAccountAutoSwitchRequest(draft: draft, isEnabled: enabled()) == nil)
        }
        #expect(reads == 0)
    }

    @Test(arguments: [
        "rate_limit: Rate limited",
        "overloaded: Overloaded",
        "usage_limited_elsewhere",
        "",
    ])
    func onlyTheUsageLimitTokenCounts(detail: String) {
        #expect(ClaudeAccountAutoSwitchRequest(draft: fixture.draft(detail: detail), isEnabled: true) == nil)
    }

    @Test
    func aUsageLimitWithoutAMessageStillCounts() {
        #expect(ClaudeAccountAutoSwitchRequest(draft: fixture.draft(detail: "usage_limit"), isEnabled: true) != nil)
    }

    @Test
    func theAttentionEchoWithoutDetailDoesNotCount() {
        // The hook's second error event carries the notification and no detail.
        #expect(ClaudeAccountAutoSwitchRequest(draft: fixture.draft(detail: .some(nil)), isEnabled: true) == nil)
    }

    @Test
    func unattributedNestedAndForeignEventsDoNotCount() {
        let drafts = [
            fixture.draft(workspaceId: .some(nil), surfaceId: .some(nil), unattributedReason: "target-unresolved"),
            fixture.draft(surfaceId: .some(nil)),
            fixture.draft(workspaceId: "not-a-uuid"),
            fixture.draft(isSubagent: true),
            fixture.draft(source: "codex"),
            fixture.draft(kind: .turnCompleted),
        ]
        for draft in drafts {
            #expect(ClaudeAccountAutoSwitchRequest(draft: draft, isEnabled: true) == nil, "\(draft)")
        }
    }

    // MARK: Which account

    @Test
    func aPaneOnAnotherMachineNeverSwitchesOrMarksAnything() {
        #expect(fixture.decide(fixture.request(), pane: .onAnotherMachine) == .ignore)
    }

    @Test
    func aPaneWithoutAClaudeSessionIsIgnored() {
        #expect(fixture.decide(fixture.request(), pane: .missing) == .ignore)
    }

    @Test
    func aTrustedNextAccountGetsTheConversationAndAContinue() throws {
        let registry = fixture.registry()
        let current = try #require(registry.account(named: ClaudeAccountRegistry.defaultAccountName))
        let work = try #require(registry.account(named: "work"))
        let reset = try #require(ClaudeUsageLimitReset.resetDate(
            inMessage: fixture.seoulMessage,
            now: fixture.now,
            timeZone: fixture.seoul
        ))

        #expect(fixture.decide(fixture.request(), pane: fixture.pane(registry: registry)) == .switchAccount(
            to: work,
            sendContinue: true,
            exhausted: .init(account: current, accountKey: fixture.defaultKey, until: reset, quotedReset: reset)
        ))
    }

    @Test
    func anUntrustedNextAccountIsSwitchedToWithoutAContinue() {
        let action = fixture.decide(fixture.request(), pane: fixture.pane(), isTrusted: { _ in false })

        guard case .switchAccount(let target, let sendContinue, _) = action else {
            Issue.record("expected a switch, got \(action)")
            return
        }
        #expect(target.name == "work")
        #expect(!sendContinue)
    }

    @Test
    func whenEveryOtherAccountIsExhaustedOnlyTheLimitIsRecorded() {
        let action = fixture.decide(
            fixture.request(),
            pane: fixture.pane(),
            stored: [fixture.workKey: fixture.now.addingTimeInterval(3600)]
        )

        guard case .markExhaustedOnly(let exhaustion) = action else {
            Issue.record("expected only a mark, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == fixture.defaultKey)
    }

    @Test
    func withOnlyTheDefaultAccountTheLimitIsStillRecorded() {
        let registry = ClaudeAccountRegistry(declarations: [], homeDirectory: fixture.home)

        let action = fixture.decide(fixture.request(), pane: fixture.pane(registry: registry))

        #expect(action.exhaustion?.accountKey == fixture.defaultKey)
        if case .switchAccount = action { Issue.record("nothing to switch to, got \(action)") }
    }

    @Test
    func aLimitMessageWithoutAResetTimeUsesTheFallbackAndQuotesNothing() throws {
        let request = fixture.request(detail: "usage_limit: Claude usage limit reached")

        let exhaustion = try #require(fixture.decide(request, pane: fixture.pane()).exhaustion)

        #expect(exhaustion.until == fixture.now.addingTimeInterval(ClaudeUsageLimitReset.fallbackInterval))
        #expect(exhaustion.quotedReset == nil)
    }

    @Test
    func aQuotedResetThatAlreadyPassedUsesTheFallback() throws {
        // "Oct 25 at 9am" read at noon that day parses to this morning: recording it would
        // expire at once and leave the account looking free.
        let request = fixture.request(detail: "usage_limit: You've hit your weekly limit · resets Oct 25 at 9am (Asia/Seoul)")

        let exhaustion = try #require(fixture.decide(request, pane: fixture.pane()).exhaustion)

        #expect(exhaustion.until == fixture.now.addingTimeInterval(ClaudeUsageLimitReset.fallbackInterval))
        #expect(exhaustion.quotedReset == nil)
    }

    @Test
    func theNewAccountHittingItsLimitTooNeverReturnsToTheExhaustedOne() {
        // The first report moved default to work and marked default. When work reports a limit
        // right after, default is still exhausted: work is marked, and nothing switches back.
        let action = fixture.decide(
            fixture.request(eventId: "event-2"),
            pane: fixture.pane(current: "work"),
            stored: [fixture.defaultKey: fixture.now.addingTimeInterval(3600)]
        )

        guard case .markExhaustedOnly(let exhaustion) = action else {
            Issue.record("expected only a mark, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == fixture.workKey)
    }

    @Test
    func aThirdAccountIsTriedWhenTheNextOneIsExhausted() {
        let registry = fixture.registry(extra: [ClaudeAccountDeclaration(name: "spare", configDir: "~/.claude-spare")])

        let action = fixture.decide(
            fixture.request(),
            pane: fixture.pane(current: "work", registry: registry),
            stored: ["\(fixture.home)/.claude-spare": fixture.now.addingTimeInterval(3600)]
        )

        guard case .switchAccount(let target, true, _) = action else {
            Issue.record("expected a trusted switch, got \(action)")
            return
        }
        #expect(target.isDefault)
    }

    @Test
    func anAccountWithoutAClaudeConfigIsNeverChosen() {
        // A config directory that is gone, or has no .claude.json, is skipped: the switch would
        // land on a login screen, or create the directory.
        let noWork: (ClaudeAccount) -> Bool = { $0.name != "work" }
        #expect(fixture.decide(fixture.request(), pane: fixture.pane(), isUsable: noWork).exhaustion != nil)
        if case .switchAccount = fixture.decide(fixture.request(), pane: fixture.pane(), isUsable: noWork) {
            Issue.record("work has no config and must not be chosen")
        }

        let registry = fixture.registry(extra: [ClaudeAccountDeclaration(name: "spare", configDir: "~/.claude-spare")])
        let action = fixture.decide(fixture.request(), pane: fixture.pane(registry: registry), isUsable: noWork)
        guard case .switchAccount(let target, _, _) = action else {
            Issue.record("expected a switch to spare, got \(action)")
            return
        }
        #expect(target.name == "spare")
    }
}
