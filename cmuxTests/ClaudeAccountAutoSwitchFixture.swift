import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Shared inputs for the automatic Claude account switch's decision tests: one pane, a usage
/// limit reported at noon in Seoul, and the user's `work` account.
struct ClaudeAccountAutoSwitchFixture {
    let home = "/Users/cmux-test"
    let workspaceId = UUID(uuidString: "0D7C6F8B-2E64-4C1B-9A55-6B1F2C3D4E5F")!
    let panelId = UUID(uuidString: "6A1C2F7E-3B1D-4E55-9F0A-0C2B7D4E8F11")!
    let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
    let seoulMessage = "You've hit your session limit · resets 6:50pm (Asia/Seoul)"
    /// 2026-10-25 12:00 in Seoul, also when the limit was reported.
    let now = Date(timeIntervalSince1970: 1_792_897_200)
    var seoul: TimeZone { TimeZone(identifier: "Asia/Seoul")! }
    var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    var workKey: String { "\(home)/.claude-work" }
    var defaultKey: String { "\(home)/.claude" }

    func registry(extra: [ClaudeAccountDeclaration] = []) -> ClaudeAccountRegistry {
        ClaudeAccountRegistry(
            declarations: [ClaudeAccountDeclaration(name: "work", configDir: "~/.claude-work")] + extra,
            homeDirectory: home
        )
    }

    /// A local pane running `current` (by name) under `registry`.
    func pane(
        current name: String = ClaudeAccountRegistry.defaultAccountName,
        registry: ClaudeAccountRegistry? = nil
    ) -> ClaudeAccountAutoSwitchRequest.Pane {
        let registry = registry ?? self.registry()
        return .local(current: registry.account(named: name)!, registry: registry, workingDirectory: "\(home)/project")
    }

    func request(
        detail: String? = nil,
        pendingWork: Bool = false,
        eventId: String = "event-1"
    ) -> ClaudeAccountAutoSwitchRequest {
        ClaudeAccountAutoSwitchRequest(
            draft: draft(eventId: eventId, pendingWork: pendingWork, detail: .some(detail ?? "usage_limit: \(seoulMessage)")),
            isEnabled: true
        )!
    }

    /// The decision with every input defaulting to "nothing in the way".
    func decide(
        _ request: ClaudeAccountAutoSwitchRequest,
        pane: ClaudeAccountAutoSwitchRequest.Pane,
        isEnabled: Bool = true,
        stored: [String: Date] = [:],
        ledger: ClaudeAccountAutoSwitchLedger = ClaudeAccountAutoSwitchLedger(),
        sourceScreen: AgentAutoResumeCoordinator.ScreenState = .unknown,
        isUsable: (ClaudeAccount) -> Bool = { _ in true },
        isTrusted: (ClaudeAccount) -> Bool = { _ in true }
    ) -> ClaudeAccountAutoSwitchAction {
        request.action(
            pane: pane,
            isEnabled: isEnabled,
            storedExhaustion: stored,
            ledger: ledger,
            sourceScreen: sourceScreen,
            isUsable: isUsable,
            isTrusted: isTrusted,
            now: now,
            timeZone: seoul,
            homeDirectory: home
        )
    }

    /// A `StopFailure` usage-limit draft. `.some(nil)` clears an optional field; leaving the
    /// argument out keeps the attributed default.
    func draft(
        eventId: String = "event-1",
        kind: AgentJournalEventKind = .errorReported,
        source: String = "claude",
        workspaceId: String?? = .none,
        surfaceId: String?? = .none,
        unattributedReason: String? = nil,
        isSubagent: Bool = false,
        pendingWork: Bool = false,
        detail: String?? = .none
    ) -> AgentJournalEventDraft {
        AgentJournalEventDraft(
            eventId: eventId,
            kind: kind,
            occurredAtMs: nowMs,
            source: source,
            agentKey: "claude_code",
            sessionId: sessionId,
            workspaceId: workspaceId ?? self.workspaceId.uuidString,
            surfaceId: surfaceId ?? panelId.uuidString,
            unattributedReason: unattributedReason,
            isSubagent: isSubagent,
            pendingWork: pendingWork,
            nativeEvent: "StopFailure",
            detail: detail ?? "usage_limit: \(seoulMessage)"
        )
    }
}
