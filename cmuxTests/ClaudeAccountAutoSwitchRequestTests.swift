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
    private let home = "/Users/cmux-test"
    private let workspaceId = UUID(uuidString: "0D7C6F8B-2E64-4C1B-9A55-6B1F2C3D4E5F")!
    private let panelId = UUID(uuidString: "6A1C2F7E-3B1D-4E55-9F0A-0C2B7D4E8F11")!
    private let seoulMessage = "You've hit your session limit · resets 6:50pm (Asia/Seoul)"
    /// 2026-10-25 12:00 in Seoul.
    private let now = Date(timeIntervalSince1970: 1_792_897_200)

    // MARK: Which events count

    @Test
    func theStopFailureUsageLimitEventIsARequest() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))

        #expect(request.workspaceId == workspaceId)
        #expect(request.panelId == panelId)
        #expect(request.detail == "usage_limit: \(seoulMessage)")
        #expect(request.eventId == "event-1")
    }

    @Test
    func nothingHappensWhileTheSettingIsOff() {
        #expect(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: false) == nil)
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
            usageLimitDraft(kind: .turnCompleted),
            usageLimitDraft(detail: "rate_limit: Rate limited"),
            usageLimitDraft(source: "codex"),
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
        #expect(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(detail: detail), isEnabled: true) == nil)
    }

    @Test
    func aUsageLimitWithoutAMessageStillCounts() {
        #expect(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(detail: "usage_limit"), isEnabled: true) != nil)
    }

    @Test
    func theAttentionEchoWithoutDetailDoesNotCount() {
        // The hook's second error event carries the notification and no detail.
        #expect(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(detail: .some(nil)), isEnabled: true) == nil)
    }

    @Test
    func unattributedNestedAndForeignEventsDoNotCount() {
        let drafts = [
            usageLimitDraft(workspaceId: .some(nil), surfaceId: .some(nil), unattributedReason: "target-unresolved"),
            usageLimitDraft(surfaceId: .some(nil)),
            usageLimitDraft(workspaceId: "not-a-uuid"),
            usageLimitDraft(isSubagent: true),
            usageLimitDraft(source: "codex"),
            usageLimitDraft(kind: .turnCompleted),
        ]
        for draft in drafts {
            #expect(ClaudeAccountAutoSwitchRequest(draft: draft, isEnabled: true) == nil, "\(draft)")
        }
    }

    // MARK: What to do

    @Test
    func aPaneOnAnotherMachineNeverSwitchesOrMarksAnything() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))

        #expect(request.action(
            pane: .onAnotherMachine,
            exhaustedKeys: [],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        ) == .ignore)
    }

    @Test
    func aPaneWithoutAClaudeSessionIsIgnored() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))

        #expect(request.action(
            pane: .missing,
            exhaustedKeys: [],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        ) == .ignore)
    }

    @Test
    func aTrustedNextAccountGetsTheConversationAndAContinue() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))
        let registry = makeRegistry()
        let current = try #require(registry.account(named: ClaudeAccountRegistry.defaultAccountName))
        let work = try #require(registry.account(named: "work"))
        let reset = try #require(ClaudeUsageLimitReset.resetDate(inMessage: seoulMessage, now: now, timeZone: seoul))

        let action = request.action(
            pane: .local(current: current, registry: registry, workingDirectory: "\(home)/project"),
            exhaustedKeys: [],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        #expect(action == .switchAccount(to: work, sendContinue: true, exhausted: .init(
            account: current,
            accountKey: "\(home)/.claude",
            until: reset,
            quotedReset: reset
        )))
    }

    @Test
    func anUntrustedNextAccountIsSwitchedToWithoutAContinue() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))
        let registry = makeRegistry()
        let current = try #require(registry.account(named: ClaudeAccountRegistry.defaultAccountName))

        let action = request.action(
            pane: .local(current: current, registry: registry, workingDirectory: "\(home)/project"),
            exhaustedKeys: [],
            isTrusted: { _ in false },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        guard case .switchAccount(let target, let sendContinue, _) = action else {
            Issue.record("expected a switch, got \(action)")
            return
        }
        #expect(target.name == "work")
        #expect(!sendContinue)
    }

    @Test
    func whenEveryOtherAccountIsExhaustedOnlyTheLimitIsRecorded() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))
        let registry = makeRegistry()
        let current = try #require(registry.account(named: ClaudeAccountRegistry.defaultAccountName))

        let action = request.action(
            pane: .local(current: current, registry: registry, workingDirectory: "\(home)/project"),
            exhaustedKeys: ["\(home)/.claude-work"],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        guard case .markExhaustedOnly(let exhaustion) = action else {
            Issue.record("expected only a mark, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == "\(home)/.claude")
    }

    @Test
    func withOnlyTheDefaultAccountTheLimitIsStillRecorded() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))
        let registry = ClaudeAccountRegistry(declarations: [], homeDirectory: home)
        let current = try #require(registry.accounts.first)

        let action = request.action(
            pane: .local(current: current, registry: registry, workingDirectory: nil),
            exhaustedKeys: [],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        #expect(action.exhaustion?.accountKey == "\(home)/.claude")
        if case .switchAccount = action { Issue.record("nothing to switch to, got \(action)") }
    }

    @Test
    func aLimitMessageWithoutAResetTimeUsesTheFallbackAndQuotesNothing() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(
            draft: usageLimitDraft(detail: "usage_limit: Claude usage limit reached"),
            isEnabled: true
        ))
        let registry = makeRegistry()
        let current = try #require(registry.account(named: ClaudeAccountRegistry.defaultAccountName))

        let exhaustion = try #require(request.action(
            pane: .local(current: current, registry: registry, workingDirectory: nil),
            exhaustedKeys: [],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        ).exhaustion)

        #expect(exhaustion.until == now.addingTimeInterval(ClaudeUsageLimitReset.fallbackInterval))
        #expect(exhaustion.quotedReset == nil)
    }

    @Test
    func theNewAccountHittingItsLimitTooNeverReturnsToTheExhaustedOne() throws {
        // The first report moved default to work and marked default. When work reports a limit
        // right after, default is still exhausted: work is marked, and nothing switches back.
        let request = try #require(ClaudeAccountAutoSwitchRequest(
            draft: usageLimitDraft(eventId: "event-2"),
            isEnabled: true
        ))
        let registry = makeRegistry()
        let work = try #require(registry.account(named: "work"))

        let action = request.action(
            pane: .local(current: work, registry: registry, workingDirectory: "\(home)/project"),
            exhaustedKeys: ["\(home)/.claude"],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        guard case .markExhaustedOnly(let exhaustion) = action else {
            Issue.record("expected only a mark, got \(action)")
            return
        }
        #expect(exhaustion.accountKey == "\(home)/.claude-work")
    }

    @Test
    func aThirdAccountIsTriedWhenTheNextOneIsExhausted() throws {
        let request = try #require(ClaudeAccountAutoSwitchRequest(draft: usageLimitDraft(), isEnabled: true))
        let registry = makeRegistry(extra: [ClaudeAccountDeclaration(name: "spare", configDir: "~/.claude-spare")])
        let work = try #require(registry.account(named: "work"))

        let action = request.action(
            pane: .local(current: work, registry: registry, workingDirectory: "\(home)/project"),
            exhaustedKeys: ["\(home)/.claude-spare"],
            isTrusted: { _ in true },
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )

        guard case .switchAccount(let target, true, _) = action else {
            Issue.record("expected a trusted switch, got \(action)")
            return
        }
        #expect(target.isDefault)
    }

    // MARK: Helpers

    private var seoul: TimeZone { TimeZone(identifier: "Asia/Seoul")! }

    private func makeRegistry(extra: [ClaudeAccountDeclaration] = []) -> ClaudeAccountRegistry {
        ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")] + extra,
            homeDirectory: home
        )
    }

    private func usageLimitDraft(
        eventId: String = "event-1",
        kind: AgentJournalEventKind = .errorReported,
        source: String = "claude",
        // `.some(nil)` clears a field; leaving the argument out keeps the attributed default.
        workspaceId: String?? = .none,
        surfaceId: String?? = .none,
        unattributedReason: String? = nil,
        isSubagent: Bool = false,
        detail: String?? = .none
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            eventId: eventId,
            kind: kind,
            occurredAtMs: Int64(now.timeIntervalSince1970 * 1000),
            source: source,
            agentKey: "claude_code",
            sessionId: "a22293b7-bcef-4707-8439-2f538c8517a4",
            workspaceId: workspaceId ?? self.workspaceId.uuidString,
            surfaceId: surfaceId ?? panelId.uuidString,
            unattributedReason: unattributedReason,
            isSubagent: isSubagent,
            nativeEvent: "StopFailure",
            detail: detail ?? "usage_limit: \(seoulMessage)"
        )
    }
}
