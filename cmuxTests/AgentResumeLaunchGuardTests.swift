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

    /// A launch that claims but never actually happens (e.g. terminal
    /// surface creation fails) must free its session immediately rather than
    /// blocking a legitimate resume until the TTL elapses (#8446).
    @Test
    func releaseAllowsImmediateReclaim() {
        let launchGuard = AgentResumeLaunchGuard()
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == false)
        launchGuard.releaseResumeLaunch(kind: "codex", sessionId: "session-1")
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-1") == true)
    }

    @Test
    func releasingAnUnclaimedSessionIsHarmless() {
        let launchGuard = AgentResumeLaunchGuard()
        launchGuard.releaseResumeLaunch(kind: "codex", sessionId: "never-claimed")
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "never-claimed") == true)
    }

    /// Expired claims must not accumulate forever in a long-running app
    /// process; each new claim call prunes stale entries so the dictionary
    /// stays bounded by currently-live sessions, not every session ever
    /// resumed (#8446).
    @Test
    func expiredClaimsAreEvictedRatherThanRetainedIndefinitely() {
        var now = Date(timeIntervalSince1970: 0)
        let launchGuard = AgentResumeLaunchGuard(dateProvider: { now })
        for index in 0..<50 {
            #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-\(index)") == true)
            now = now.addingTimeInterval(61)
        }
        // Every prior claim is now well past the TTL; a fresh claim call
        // should prune them all rather than retaining 50 stale entries.
        #expect(launchGuard.claimResumeLaunch(kind: "codex", sessionId: "session-fresh") == true)
        #expect(launchGuard.claimedSessionKeys.count == 1)
    }
}
