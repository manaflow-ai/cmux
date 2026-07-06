import CMUXMobileCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for ``HostMobileViewportReportModel``, the shared
/// mobile-terminal viewport state machine drained out of `TerminalController`.
///
/// These pin the faithful behavior of the legacy `mobileViewportReports*`
/// methods: clamping, shared-minimum capping, sticky-vs-TTL expiry, and the
/// surface-limit side effects, using a recording limiter and an injected `Date`
/// so expiry is deterministic without sleeping on a real clock.
@Suite(.serialized)
@MainActor
struct HostMobileViewportReportModelTests {
    /// Records the limiter side effects so a test can assert the exact apply /
    /// clear calls (and their resolved minimum grid) the model produced.
    final class RecordingLimiter: MobileViewportSurfaceLimiting {
        struct Apply: Equatable {
            var surfaceID: UUID
            var columns: Int
            var rows: Int
            var reason: String
        }
        struct Clear: Equatable, Hashable {
            var surfaceID: UUID
            var reason: String
        }
        var applies: [Apply] = []
        var clears: [Clear] = []

        func applyMobileViewportLimit(surfaceID: UUID, columns: Int, rows: Int, reason: String) {
            applies.append(Apply(surfaceID: surfaceID, columns: columns, rows: rows, reason: reason))
        }

        func clearMobileViewportLimit(surfaceID: UUID, reason: String) {
            clears.append(Clear(surfaceID: surfaceID, reason: reason))
        }
    }

    private func makeModel(
        limiter: RecordingLimiter,
        now: @escaping @MainActor () -> Date
    ) -> HostMobileViewportReportModel {
        HostMobileViewportReportModel(limiter: limiter, clock: ContinuousClock(), now: now)
    }

    @Test func clampsReportedGridToSupportedRange() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surface = UUID()

        // Below the floor and above the ceiling clamp to 20...300 / 5...120.
        model.apply(surfaceID: surface, clientID: "c", columns: 1, rows: 1, sticky: true)
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 20, rows: 5, reason: "mobile.terminal.input"))

        model.apply(surfaceID: surface, clientID: "c", columns: 9999, rows: 9999, sticky: true)
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 300, rows: 120, reason: "mobile.terminal.input"))
    }

    @Test func capsToSmallestAttachedViewport() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surface = UUID()

        model.apply(surfaceID: surface, clientID: "ios", columns: 84, rows: 42, sticky: true)
        model.apply(surfaceID: surface, clientID: "ipad", columns: 54, rows: 15, sticky: true)

        // The smallest attached cols and rows win independently.
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 54, rows: 15, reason: "mobile.terminal.input"))
        #expect(model.debugReportClientIDsForTesting(surfaceID: surface) == Set(["ios", "ipad"]))
    }

    @Test func nonStickyReportExpiresOnPrune() {
        let limiter = RecordingLimiter()
        var clock = Date(timeIntervalSince1970: 0)
        let model = makeModel(limiter: limiter, now: { clock })
        let surface = UUID()

        // A non-sticky (input-piggyback) report from a peer plus a sticky one.
        model.apply(surfaceID: surface, clientID: "typed-once", columns: 30, rows: 10, sticky: false)
        model.apply(surfaceID: surface, clientID: "attached", columns: 80, rows: 40, sticky: true)
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 30, rows: 10, reason: "mobile.terminal.input"))

        // Advance past the TTL and prune: the non-sticky report drops, the
        // sticky one remains, and the surface re-caps to the sticky grid.
        clock = Date(timeIntervalSince1970: HostMobileViewportReportModel.reportTTL + 1)
        model.prune(surfaceID: surface, reason: "test.expire")
        #expect(model.debugReportClientIDsForTesting(surfaceID: surface) == Set(["attached"]))
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 80, rows: 40, reason: "test.expire"))
    }

    @Test func stickyReportSurvivesPrune() {
        let limiter = RecordingLimiter()
        var clock = Date(timeIntervalSince1970: 0)
        let model = makeModel(limiter: limiter, now: { clock })
        let surface = UUID()

        model.apply(surfaceID: surface, clientID: "attached", columns: 60, rows: 30, sticky: true)
        clock = Date(timeIntervalSince1970: 10_000)
        model.prune(surfaceID: surface, reason: "test.expire")

        // Sticky reports never expire on the TTL; nothing was cleared.
        #expect(model.debugReportClientIDsForTesting(surfaceID: surface) == Set(["attached"]))
        #expect(limiter.clears.isEmpty)
    }

    @Test func clearingLastReportReleasesSurface() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surface = UUID()

        model.apply(surfaceID: surface, clientID: "only", columns: 50, rows: 20, sticky: true)
        model.clear(surfaceID: surface, clientID: "only", reason: "disconnect")

        #expect(model.debugReportClientIDsForTesting(surfaceID: surface) == nil)
        #expect(limiter.clears.last == .init(surfaceID: surface, reason: "disconnect"))
    }

    @Test func clearingOneOfManyRecomputesMinimum() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surface = UUID()

        model.apply(surfaceID: surface, clientID: "small", columns: 40, rows: 12, sticky: true)
        model.apply(surfaceID: surface, clientID: "big", columns: 90, rows: 50, sticky: true)
        model.clear(surfaceID: surface, clientID: "small", reason: "disconnect")

        // The surface re-caps to the surviving client's grid, not cleared.
        #expect(model.debugReportClientIDsForTesting(surfaceID: surface) == Set(["big"]))
        #expect(limiter.applies.last == .init(surfaceID: surface, columns: 90, rows: 50, reason: "disconnect"))
        #expect(limiter.clears.isEmpty)
    }

    @Test func clearByClientIDsDropsAcrossSurfaces() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surfaceA = UUID()
        let surfaceB = UUID()

        model.apply(surfaceID: surfaceA, clientID: "ios", columns: 50, rows: 20, sticky: true)
        model.apply(surfaceID: surfaceA, clientID: "ipad", columns: 60, rows: 30, sticky: true)
        model.apply(surfaceID: surfaceB, clientID: "ios", columns: 70, rows: 40, sticky: true)

        // Closing the ios connection drops its reports everywhere; ipad stays.
        model.clear(clientIDs: ["ios"], reason: "connection.closed")
        #expect(model.debugReportClientIDsForTesting(surfaceID: surfaceA) == Set(["ipad"]))
        #expect(model.debugReportClientIDsForTesting(surfaceID: surfaceB) == nil)
        #expect(limiter.clears.contains(.init(surfaceID: surfaceB, reason: "connection.closed")))
    }

    @Test func clearAllReleasesEverySurface() {
        let limiter = RecordingLimiter()
        let model = makeModel(limiter: limiter, now: { Date(timeIntervalSince1970: 0) })
        let surfaceA = UUID()
        let surfaceB = UUID()

        model.apply(surfaceID: surfaceA, clientID: "a", columns: 50, rows: 20, sticky: true)
        model.apply(surfaceID: surfaceB, clientID: "b", columns: 60, rows: 30, sticky: true)
        model.clearAll(reason: "host.stopped")

        #expect(model.debugReportClientIDsForTesting(surfaceID: surfaceA) == nil)
        #expect(model.debugReportClientIDsForTesting(surfaceID: surfaceB) == nil)
        #expect(Set(limiter.clears) == Set([
            .init(surfaceID: surfaceA, reason: "host.stopped"),
            .init(surfaceID: surfaceB, reason: "host.stopped"),
        ]))
    }
}
