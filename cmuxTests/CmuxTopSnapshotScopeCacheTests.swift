import Testing
import Foundation
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for the cmux-scope attribution cache used by system.top.
// See https://github.com/manaflow-ai/cmux/issues/5756.
//
// `.serialized` because these tests share the process-global cmux-top scope
// cache (`CmuxTopProcessSnapshot.cachedCMUXScope` / `pruneCMUXScopeCache`); they
// must not interleave with each other.
@Suite(.serialized)
struct CmuxTopSnapshotScopeCacheTests {
    // ~1s, well within the negative TTL.
    static let nowNanoseconds: UInt64 = 1_000_000_000
    static let afterNegativeTTLNanoseconds = nowNanoseconds
        + cmuxTopNegativeScopeTTLNanoseconds
        + 1

    // Before the fix, a process with no cmux scope was a permanent cache miss, so
    // every system.top poll re-ran the 3-sysctl probe for every non-cmux process
    // on the machine. The negative result must now be cached within the TTL.
    @Test func negativeScopeResultIsCachedWithinTTL() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_001,
            startSeconds: 1_700_000_001,
            startMicroseconds: 11
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(nil)
        }

        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_001, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_001, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)

        #expect(first == nil)
        #expect(second == nil)
        #expect(probeCount == 1, "non-cmux process should be probed once per TTL, not on every poll")
    }

    @Test func positiveScopeResultIsCachedAcrossPolls() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_002,
            startSeconds: 1_700_000_002,
            startMicroseconds: 22
        )
        let expected = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "99999999-9999-9999-9999-999999999999"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(expected)
        }

        // A discovered scope is cached indefinitely, even far past the negative TTL.
        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_002, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_002, cacheKey: cacheKey, nowNanoseconds: Self.afterNegativeTTLNanoseconds, probe: probe)

        #expect(first == expected)
        #expect(second == expected)
        #expect(probeCount == 1)
    }

    // A transient read failure (process exited mid-probe, pid reuse, failed
    // sysctl) must not be cached as a nil, so the next poll retries and can still
    // attribute a live cmux process.
    @Test func transientProbeFailureIsNotCachedAndRetries() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_003,
            startSeconds: 1_700_000_003,
            startMicroseconds: 33
        )
        let expected = CmuxTopProcessScope(
            workspaceID: nil,
            surfaceID: UUID(uuidString: "abababab-abab-abab-abab-abababababab"),
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            // Fail the first two polls, then resolve.
            return probeCount < 3 ? .unavailable : .resolved(expected)
        }

        let first = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        let second = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        let third = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        let fourth = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_003, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)

        #expect(first == nil)
        #expect(second == nil)
        #expect(third == expected)
        #expect(fourth == expected, "resolved scope should now be cached")
        #expect(probeCount == 3, "transient failures retry; the resolved result is cached")
    }

    // The cache key is (pid, process start time), which an `exec` does not change.
    // A process first sampled in its fork-before-exec window, or one that execs
    // into a cmux-scoped command later, must be re-probed once the negative TTL
    // elapses so it is eventually attributed (https://github.com/manaflow-ai/cmux/issues/5756).
    @Test func negativeScopeIsReprobedAfterTTLExpiry() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_004,
            startSeconds: 1_700_000_004,
            startMicroseconds: 44
        )
        let postExecScope = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "12121212-1212-1212-1212-121212121212"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        var probeCount = 0
        var resolvedScope: CmuxTopProcessScope?
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { _, _ in
            probeCount += 1
            return .resolved(resolvedScope)
        }

        // Sampled pre-exec: no scope yet, cached negative.
        let preExec = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        // Polled again within the TTL: served from the negative cache, no re-probe.
        let withinTTL = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        #expect(preExec == nil)
        #expect(withinTTL == nil)
        #expect(probeCount == 1)

        // Process has since execed into a cmux-scoped command; after the TTL the
        // negative entry expires and the next poll re-probes and attributes it.
        resolvedScope = postExecScope
        let afterExpiry = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_004, cacheKey: cacheKey, nowNanoseconds: Self.afterNegativeTTLNanoseconds, probe: probe)
        #expect(afterExpiry == postExecScope)
        #expect(probeCount == 2, "expired negative entry must be re-probed")
    }

    @Test func liveProcessScopeProbeResolves() throws {
        let pid = Int(Darwin.getpid())
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(expectedSize))
        try #require(size == expectedSize)
        let cacheKey = CmuxTopProcessSnapshot.scopeCacheKey(from: info)

        let result = CmuxTopProcessSnapshot.cmuxScopeProbe(for: pid, expectedCacheKey: cacheKey)

        switch result {
        case .resolved:
            break
        case .unavailable:
            Issue.record("live process probe should resolve, even when it has no cmux scope")
        }
    }

    // capture() runs concurrently. A slower sample that probed a process before
    // it execed (resolving nil) must not, on its delayed write, clobber a
    // positive scope that a faster overlapping sample already discovered.
    @Test func negativeProbeDoesNotClobberConcurrentlyDiscoveredPositive() {
        CmuxTopProcessSnapshot.pruneCMUXScopeCache(activeKeys: [])
        let cacheKey = CmuxTopProcessScopeCacheKey(
            pid: 901_005,
            startSeconds: 1_700_000_005,
            startMicroseconds: 55
        )
        let positive = CmuxTopProcessScope(
            workspaceID: UUID(uuidString: "13131313-1313-1313-1313-131313131313"),
            surfaceID: nil,
            attributionReason: "cmux-environment"
        )
        // This (older) sample resolves nil, but simulates a concurrent capture
        // discovering and caching the positive scope while the probe is in flight.
        let probe: (Int, CmuxTopProcessScopeCacheKey) -> CmuxTopProcessScopeProbeResult = { pid, key in
            _ = CmuxTopProcessSnapshot.cachedCMUXScope(
                for: pid, cacheKey: key, nowNanoseconds: Self.nowNanoseconds) { _, _ in .resolved(positive) }
            return .resolved(nil)
        }

        let result = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_005, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds, probe: probe)
        #expect(result == positive, "stale negative must not clobber a concurrently discovered positive")

        // The positive entry survives for later polls.
        let nextPoll = CmuxTopProcessSnapshot.cachedCMUXScope(
            for: 901_005, cacheKey: cacheKey, nowNanoseconds: Self.nowNanoseconds) { _, _ in .resolved(nil) }
        #expect(nextPoll == positive)
    }
}
