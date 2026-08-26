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
        let resolver = TerminalCallerTTYResolver(
            reportedCandidates: [
                (binding: first, ttyName: "ttys8362"),
                (binding: second, ttyName: "/dev/ttys8362"),
            ]
        )

        #expect(resolver.binding(for: "ttys8362") == nil)
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
