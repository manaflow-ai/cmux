import XCTest
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The notifications header (Cmd+I) shows one badge per running-agent
/// provider. The projection must drop zero-count providers, keep a stable
/// provider order, and produce nothing when no agents are running (so the
/// header renders no empty chrome).
@MainActor
final class NotificationAgentCountsSegmentsTests: XCTestCase {
    func testSegmentsDropZeroCountsAndKeepProviderOrder() {
        var counts = SleepyAgentCounts()
        counts.claude = 3
        counts.pi = 1
        counts.other = 2
        let segments = NotificationAgentCountsView.segments(for: counts)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(Array(segments.map(\.name).prefix(2)), ["Claude", "pi"])
        XCTAssertEqual(segments.map(\.count), [3, 1, 2])
        XCTAssertFalse(segments.contains { $0.name == "Codex" })
        XCTAssertFalse(segments.contains { $0.name == "opencode" })
    }

    func testSegmentsEmptyWhenNoAgentsRunning() {
        XCTAssertTrue(NotificationAgentCountsView.segments(for: SleepyAgentCounts()).isEmpty)
    }
}
