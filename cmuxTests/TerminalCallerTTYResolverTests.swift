import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalCallerTTYResolverTests {
    @Test func liveTargetOutranksStaleReportedBinding() {
        let live = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let stale = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let resolver = TerminalCallerTTYResolver(
            liveCandidates: [(binding: live, ttyName: "/dev/ttys8362")],
            reportedCandidates: [(binding: stale, ttyName: "ttys8362")]
        )

        #expect(resolver.binding(for: "ttys8362") == live)
    }

    @Test func uniqueReportedInnerTTYResolvesNestedTmuxCaller() {
        let target = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let resolver = TerminalCallerTTYResolver(
            liveCandidates: [(binding: target, ttyName: "ttys9999")],
            reportedCandidates: [(binding: target, ttyName: "/dev/ttys8362")]
        )

        #expect(resolver.binding(for: "ttys8362") == target)
    }

    @Test func duplicateReportedBindingsFailClosed() {
        let first = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let second = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let candidates = [
            (binding: first, ttyName: "ttys8362"),
            (binding: second, ttyName: "/dev/ttys8362"),
        ]

        // Dictionary-backed TTY metadata has no stable iteration order. Every
        // permutation must remain ambiguous instead of selecting whichever row
        // happens to be visited first.
        let permutations: [[(binding: TerminalCallerTTYBinding, ttyName: String)]] = [
            candidates,
            Array(candidates.reversed()),
        ]
        for permutation in permutations {
            let resolver = TerminalCallerTTYResolver(reportedCandidates: permutation)
            #expect(resolver.binding(for: "ttys8362") == nil)
        }
    }

    @Test func currentRuntimeBindingWinsOverRestoredDuplicateRegardlessOfOrder() {
        let runtime = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let restored = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())

        // The app resolver places a current Ghostty PTY in the live tier and a
        // restored shell report in the fallback tier. The strict resolver must
        // always choose the live proof, independent of candidate order.
        let liveCandidates = [
            (binding: runtime, ttyName: "/dev/ttys777"),
            (binding: TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID()), ttyName: "ttys888"),
        ]
        let restoredCandidates = [
            (binding: restored, ttyName: "ttys777"),
        ]
        let livePermutations: [[(binding: TerminalCallerTTYBinding, ttyName: String)]] = [
            liveCandidates,
            Array(liveCandidates.reversed()),
        ]
        for live in livePermutations {
            let resolver = TerminalCallerTTYResolver(
                liveCandidates: live,
                reportedCandidates: restoredCandidates
            )
            #expect(resolver.binding(for: "ttys777") == runtime)
        }
    }

    @Test func ambiguousLiveBindingsDoNotFallBackToReportedBinding() {
        let first = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let second = TerminalCallerTTYBinding(workspaceId: UUID(), surfaceId: UUID())
        let resolver = TerminalCallerTTYResolver(
            liveCandidates: [
                (binding: first, ttyName: "ttys8362"),
                (binding: second, ttyName: "ttys8362"),
            ],
            reportedCandidates: [(binding: first, ttyName: "ttys8362")]
        )

        #expect(resolver.binding(for: "ttys8362") == nil)
    }
}
