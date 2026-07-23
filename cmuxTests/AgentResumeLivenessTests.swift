import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #8446: plain (non-tmux) `codex resume` /
/// `claude --resume` surfaces must be gated on the same live-process index
/// already used for "reopen closed tab" and Fork Conversation availability,
/// instead of firing unconditionally.
@MainActor
@Suite
struct AgentResumeLivenessTests {
    private static func entry(
        kind: RestorableAgentKind = .codex,
        sessionId: String = "session-1",
        processIDs: Set<Int> = [4_242]
    ) -> RestorableAgentSessionIndex.Entry {
        RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(kind: kind, sessionId: sessionId),
            lifecycle: nil,
            updatedAt: 0,
            processLiveness: processIDs.isEmpty ? .exited : .running,
            processIDs: processIDs,
            agentProcessIDs: processIDs,
            agentProcessIdentities: [:]
        )
    }

    @Test
    func matchingLiveSessionIsReportedAsActive() {
        #expect(
            AgentResumeLiveness.hasLiveProcess(
                for: Self.entry(),
                kind: "codex",
                sessionId: "session-1"
            )
        )
    }

    @Test
    func sameSessionWithNoLiveProcessIsNotReportedAsActive() {
        #expect(
            !AgentResumeLiveness.hasLiveProcess(
                for: Self.entry(processIDs: []),
                kind: "codex",
                sessionId: "session-1"
            )
        )
    }

    @Test
    func differentSessionIdIsNotReportedAsActive() {
        #expect(
            !AgentResumeLiveness.hasLiveProcess(
                for: Self.entry(sessionId: "session-1"),
                kind: "codex",
                sessionId: "session-2"
            )
        )
    }

    @Test
    func differentKindIsNotReportedAsActive() {
        #expect(
            !AgentResumeLiveness.hasLiveProcess(
                for: Self.entry(kind: .codex),
                kind: "claude",
                sessionId: "session-1"
            )
        )
    }

    @Test
    func noEntryIsNotReportedAsActive() {
        #expect(!AgentResumeLiveness.hasLiveProcess(for: nil, kind: "codex", sessionId: "session-1"))
    }
}
