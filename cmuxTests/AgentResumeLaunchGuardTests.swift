import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #8446: two panels that reference the same
/// underlying agent session must not both be allowed to fire a resume
/// launch during the same restore pass.
@MainActor
@Suite
struct AgentResumeLaunchGuardTests {
    @Test
    func secondClaimForTheSameSessionIsRejected() {
        let launchGuard = AgentResumeLaunchGuard()
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == false)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == false)
    }

    @Test
    func differentSessionsEachClaimIndependently() {
        let launchGuard = AgentResumeLaunchGuard()
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-2") == true)
    }

    @Test
    func sameSessionIdUnderDifferentKindsClaimsIndependently() {
        let launchGuard = AgentResumeLaunchGuard()
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        #expect(launchGuard.claimResumeLaunch(kind: "claude", sessionId: "session-1") == true)
    }

    @Test
    func freshInstancesDoNotShareClaims() {
        let first = AgentResumeLaunchGuard()
        let second = AgentResumeLaunchGuard()
        #expect(first.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        #expect(second.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
    }

    /// A claim exists only to break the tie between panels racing during the
    /// same restore pass; it must expire so a much-later legitimate resume
    /// (e.g. reopening a closed tab long after the original agent exited)
    /// is never permanently blocked (#8446).
    @Test
    func claimExpiresAfterTTL() {
        var now = Date(timeIntervalSince1970: 0)
        let launchGuard = AgentResumeLaunchGuard(dateProvider: { now })
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        now = now.addingTimeInterval(61)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
    }

    @Test
    func claimDoesNotExpireBeforeTTL() {
        var now = Date(timeIntervalSince1970: 0)
        let launchGuard = AgentResumeLaunchGuard(dateProvider: { now })
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        now = now.addingTimeInterval(30)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == false)
    }
}
