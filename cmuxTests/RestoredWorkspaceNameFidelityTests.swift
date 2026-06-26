import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for restored-window name fidelity (U13/R16/KTD14): a verified
/// window keeps its real auto summary; an unverified window does NOT inherit
/// another session's summary (anti-Example-1); a user-set title is always
/// preserved regardless of verification.
@Suite struct RestoredWorkspaceNameFidelityTests {

    private let resolver = RestoredNameResolver()

    @Test func verifiedWindowKeepsItsAutoSummary() {
        // Covers R16: a verified window keeps its real summary across restore.
        let name = resolver.resolve(
            persistedTitle: "Fix order-to-go CLI",
            source: .auto,
            isVerified: true
        )
        #expect(name == .applyVerifiedSummary("Fix order-to-go CLI"))
    }

    @Test func unverifiedAutoSummaryBecomesNeutral() {
        // Anti-Example-1: a fresh / mis-mapped window must not wear a session's
        // summary it cannot prove is its own.
        let name = resolver.resolve(
            persistedTitle: "x-money-research",
            source: .auto,
            isVerified: false
        )
        #expect(name == .neutral)
    }

    @Test func userTitlePreservedEvenWhenVerified() {
        let name = resolver.resolve(
            persistedTitle: "My important window",
            source: .user,
            isVerified: true
        )
        #expect(name == .keepUserTitle("My important window"))
    }

    @Test func userTitlePreservedEvenWhenUnverified() {
        // A user title is sacrosanct — verification gates auto summaries, not user
        // intent.
        let name = resolver.resolve(
            persistedTitle: "My important window",
            source: .user,
            isVerified: false
        )
        #expect(name == .keepUserTitle("My important window"))
    }

    @Test func absentProvenancePreservesLegacyUserTitle() {
        // Snapshot decoding treats missing provenance as a legacy user title for
        // backwards compatibility; only explicit `.auto` summaries are gated.
        let name = resolver.resolve(
            persistedTitle: "Legacy title",
            source: nil,
            isVerified: false
        )
        #expect(name == .keepUserTitle("Legacy title"))
    }

    @Test func emptyOrBlankTitleIsNeutral() {
        #expect(resolver.resolve(persistedTitle: nil, source: .auto, isVerified: true) == .neutral)
        #expect(resolver.resolve(persistedTitle: "   ", source: .auto, isVerified: true) == .neutral)
        #expect(resolver.resolve(persistedTitle: "", source: .user, isVerified: false) == .neutral)
    }

    @Test func verifiedSummaryIsTrimmed() {
        let name = resolver.resolve(
            persistedTitle: "  spaced summary  ",
            source: .auto,
            isVerified: true
        )
        #expect(name == .applyVerifiedSummary("spaced summary"))
    }
}
