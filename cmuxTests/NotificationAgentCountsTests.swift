import XCTest
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The notifications header (Cmd+I popover and sidebar page) shows a single
/// running-agent total; clicking it opens a per-provider breakdown with each
/// agent's workspace and running duration. These cover the pure projections:
/// key classification, section grouping/ordering, duration sorting, and the
/// empty state (no agents -> no sections -> no badge chrome).
@MainActor
final class NotificationAgentCountsTests: XCTestCase {
    private func snapshot(
        provider: RunningAgentProvider,
        key: String = "k",
        workspace: String,
        startedSecondsAgo: Double?,
        now: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    ) -> RunningAgentSnapshot {
        RunningAgentSnapshot(
            provider: provider,
            key: key,
            workspaceId: UUID(),
            workspaceTitle: workspace,
            pid: 1234,
            startDate: startedSecondsAgo.map { now.addingTimeInterval(-$0) }
        )
    }

    func testClassifyBucketsKnownProviderKeys() {
        XCTAssertEqual(RunningAgentProvider.classify(key: "claude_code"), .claude)
        XCTAssertEqual(RunningAgentProvider.classify(key: "codex"), .codex)
        XCTAssertEqual(RunningAgentProvider.classify(key: "opencode"), .opencode)
        XCTAssertEqual(RunningAgentProvider.classify(key: "pi-swarm"), .pi)
        XCTAssertEqual(RunningAgentProvider.classify(key: "aider"), .other)
    }

    func testSectionsGroupByProviderInFixedOrderAndDropEmptyProviders() {
        let agents = [
            snapshot(provider: .codex, workspace: "b", startedSecondsAgo: 10),
            snapshot(provider: .claude, workspace: "a", startedSecondsAgo: 20),
            snapshot(provider: .claude, workspace: "c", startedSecondsAgo: 5),
        ]
        let sections = NotificationAgentBreakdownView.sections(for: agents)
        XCTAssertEqual(sections.map(\.provider), [.claude, .codex])
        XCTAssertEqual(sections[0].rows.count, 2)
        XCTAssertEqual(sections[1].rows.count, 1)
    }

    func testRowsSortLongestRunningFirstWithUnknownStartsLast() {
        let agents = [
            snapshot(provider: .claude, workspace: "young", startedSecondsAgo: 60),
            snapshot(provider: .claude, workspace: "unknown", startedSecondsAgo: nil),
            snapshot(provider: .claude, workspace: "old", startedSecondsAgo: 3_600),
        ]
        let sections = NotificationAgentBreakdownView.sections(for: agents)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].rows.map(\.workspaceTitle), ["old", "young", "unknown"])
    }

    func testSectionsEmptyWhenNoAgentsRunning() {
        XCTAssertTrue(NotificationAgentBreakdownView.sections(for: []).isEmpty)
    }

    func testDurationTextNilWithoutStartDateAndNonNegative() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertNil(NotificationAgentBreakdownView.durationText(startDate: nil, now: now))
        // A start date slightly in the future (clock skew) must not render a
        // negative duration.
        let skewed = NotificationAgentBreakdownView.durationText(
            startDate: now.addingTimeInterval(5), now: now
        )
        XCTAssertNotNil(skewed)
        XCTAssertFalse(skewed?.contains("-") ?? true)
    }
}
