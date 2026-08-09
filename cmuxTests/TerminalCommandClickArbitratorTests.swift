import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal command-click arbitrator")
struct TerminalCommandClickArbitratorTests {
    private static let candidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/TMLlaboratory",
        nativeMatchKey: "/Users/dev/project/TMLlaborator"
    )

    private static let otherCandidate = TerminalWrappedPathResolution(
        path: "/Users/dev/project/other",
        nativeMatchKey: "/Users/dev/project/other-token"
    )

    // MARK: openURLCallbackResult

    @Test("An explicit scheme always passes through, even with a prepared candidate")
    func explicitSchemePassesThroughOverPreparedCandidate() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: true,
            matchKey: Self.candidate.nativeMatchKey
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("file: scheme passes through like any other explicit scheme")
    func fileSchemePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: true,
            matchKey: "file:///Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("An exact match against a prepared candidate claims the URL")
    func exactMatchAgainstPreparedCandidateClaims() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKey
        )
        #expect(result.nextState == .overridePending(Self.candidate))
        #expect(result.shouldClaim == true)
    }

    @Test("A mismatched key against a prepared candidate passes through")
    func mismatchedKeyPassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .prepared(Self.candidate),
            hasExplicitScheme: false,
            matchKey: Self.otherCandidate.nativeMatchKey
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("No prepared state and no scheme still passes through (substring matching is never attempted)")
    func noPreparedStatePassesThrough() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: nil,
            hasExplicitScheme: false,
            matchKey: "/Users/dev/project/TMLlaboratory"
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    @Test("nativePassthrough state never re-claims a later callback")
    func nativePassthroughStateDoesNotClaim() {
        let result = TerminalCommandClickArbitrator.openURLCallbackResult(
            currentState: .nativePassthrough,
            hasExplicitScheme: false,
            matchKey: Self.candidate.nativeMatchKey
        )
        #expect(result.nextState == .nativePassthrough)
        #expect(result.shouldClaim == false)
    }

    // MARK: releaseAction

    @Test("nil final state defers to the existing word-under-cursor logic")
    func nilFinalStateDefers() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: false) == .none
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: nil, ghosttyConsumed: true) == .none
        )
    }

    @Test("nativePassthrough final state never opens the wrapped candidate")
    func nativePassthroughFinalStateOpensNothing() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: false) == .none
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(finalState: .nativePassthrough, ghosttyConsumed: true) == .none
        )
    }

    @Test("overridePending opens the candidate regardless of ghosttyConsumed")
    func overridePendingAlwaysOpens() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .overridePending(Self.candidate),
                ghosttyConsumed: true
            ) == .openWrappedCandidate(Self.candidate)
        )
    }

    @Test("prepared opens the candidate only when Ghostty didn't consume the release")
    func preparedOpensOnlyWhenNotConsumed() {
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: false
            ) == .openWrappedCandidate(Self.candidate)
        )
        #expect(
            TerminalCommandClickArbitrator.releaseAction(
                finalState: .prepared(Self.candidate),
                ghosttyConsumed: true
            ) == .none
        )
    }

    @Test("prepared and overridePending open through the same action for the same candidate")
    func preparedAndOverridePendingAgreeOnPolicy() {
        // This is the regression this arbitrator exists to prevent: clicking
        // either wrapped row must open exactly once under the same policy,
        // whether or not Ghostty's own link detection fired for the other
        // row.
        let fromTopRowClick = TerminalCommandClickArbitrator.releaseAction(
            finalState: .prepared(Self.candidate),
            ghosttyConsumed: false
        )
        let fromBottomRowClickThatGhosttyPartiallyMatched = TerminalCommandClickArbitrator.releaseAction(
            finalState: .overridePending(Self.candidate),
            ghosttyConsumed: true
        )
        #expect(fromTopRowClick == fromBottomRowClickThatGhosttyPartiallyMatched)
    }
}
