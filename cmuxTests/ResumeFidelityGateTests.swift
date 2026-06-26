import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the binding verification gate (U10/R13): the full
/// verified/unverified matrix, ordered precedence of the checks, and the
/// transcript-at-cwd vs transcript-elsewhere distinction that separates an
/// honest "missing" from the anti-Example-3 "belongs to a different cwd".
@Suite struct ResumeFidelityGateTests {

    private func facts(
        hasBinding: Bool = true,
        kind: RestorableAgentKind? = .claude,
        session: String? = "sess-123",
        resumeConstructable: Bool = true,
        atWindowCwd: Bool = true,
        elsewhere: Bool = false
    ) -> ResumeBindingFacts {
        ResumeBindingFacts(
            hasBinding: hasBinding,
            agentKind: kind,
            sessionId: session,
            resumeCommandConstructable: resumeConstructable,
            transcriptExistsAtWindowCwd: atWindowCwd,
            transcriptExistsElsewhere: elsewhere
        )
    }

    private let gate = ResumeFidelityGate()

    @Test func verifiedClaudeBindingWithTranscriptAtCwd() {
        #expect(gate.verify(facts()) == .verified)
        #expect(gate.isVerified(facts()) == true)
    }

    @Test func verifiedCodexBinding() {
        #expect(gate.verify(facts(kind: .codex)) == .verified)
    }

    @Test func noBindingIsUnverified() {
        // A panel that recorded no session pre-crash has nothing to trust.
        #expect(gate.verify(facts(hasBinding: false)) == .unverified(.noBinding))
        #expect(gate.isVerified(facts(hasBinding: false)) == false)
    }

    @Test func transcriptMissingEverywhereIsUnverified() {
        // Covers R13: a bound id with no transcript on disk is never trusted.
        let verdict = gate.verify(facts(atWindowCwd: false, elsewhere: false))
        #expect(verdict == .unverified(.transcriptMissing))
    }

    @Test func transcriptExistsButUnderDifferentCwdIsMismatch() {
        // Anti-Example-3: the transcript exists, but only under a foreign project
        // dir. Adopting it would mis-attribute another window's session.
        let verdict = gate.verify(facts(atWindowCwd: false, elsewhere: true))
        #expect(verdict == .unverified(.cwdMismatch))
    }

    @Test func missingSessionIdIsUnverified() {
        #expect(gate.verify(facts(session: nil)) == .unverified(.noSessionId))
        #expect(gate.verify(facts(session: "   ")) == .unverified(.noSessionId))
    }

    @Test func unconstructableResumeCommandIsUnverified() {
        #expect(gate.verify(facts(resumeConstructable: false)) == .unverified(.resumeUnavailable))
    }

    @Test func unsupportedAgentIsUnverified() {
        #expect(gate.verify(facts(kind: .gemini)) == .unverified(.unsupportedAgent(.gemini)))
        #expect(gate.verify(facts(kind: nil)) == .unverified(.unsupportedAgent(.custom("unknown"))))
    }

    // MARK: - Ordered precedence

    @Test func noBindingCheckedBeforeEverythingElse() {
        // Even with a broken agent/session, "no binding" is the first truth.
        let verdict = gate.verify(facts(hasBinding: false, kind: .gemini, session: nil))
        #expect(verdict == .unverified(.noBinding))
    }

    @Test func unsupportedAgentCheckedBeforeSession() {
        // An unsupported agent with no session reports the agent reason.
        let verdict = gate.verify(facts(kind: .gemini, session: nil))
        #expect(verdict == .unverified(.unsupportedAgent(.gemini)))
    }

    @Test func sessionCheckedBeforeTranscript() {
        // No session id short-circuits before any transcript reasoning.
        let verdict = gate.verify(facts(session: nil, atWindowCwd: false, elsewhere: true))
        #expect(verdict == .unverified(.noSessionId))
    }

    @Test func resumeCommandCheckedBeforeTranscript() {
        let verdict = gate.verify(facts(resumeConstructable: false, atWindowCwd: false))
        #expect(verdict == .unverified(.resumeUnavailable))
    }

    @Test func transcriptAtCwdWinsEvenIfElsewhereAlsoTrue() {
        // If a transcript exists at the window's own cwd, an additional copy
        // elsewhere is irrelevant — this window's binding is verified.
        #expect(gate.verify(facts(atWindowCwd: true, elsewhere: true)) == .verified)
    }
}
