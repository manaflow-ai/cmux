// cmuxTests/IslandSessionSortTests.swift

import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class IslandSessionSortTests: XCTestCase {

    private func make(
        phase: IslandSessionPhase,
        lastActivity: Date = Date(timeIntervalSince1970: 0)
    ) -> IslandSession {
        IslandSession(
            id: UUID(),
            workspaceId: UUID(),
            panelId: UUID(),
            agentKind: .claudeCode,
            phase: phase,
            workspaceTitle: "w",
            panelTitle: "p",
            lastActivity: lastActivity,
            unreadCount: 0,
            rawStatusValue: "x"
        )
    }

    func testPhasePrecedence() {
        let unknown = make(phase: .unknown)
        let idle    = make(phase: .idle)
        let error   = make(phase: .error)
        let waiting = make(phase: .waiting)
        let running = make(phase: .running)

        let sorted = [unknown, idle, error, waiting, running].sorted(by: <)
        XCTAssertEqual(sorted.map(\.phase), [.running, .waiting, .error, .idle, .unknown])
    }

    func testRecentActivityBreaksTies() {
        let older  = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 100))
        let newer  = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(newer < older, "Newer running session should come first")
    }

    func testTiesBetweenDifferentPhasesStillRespectPhaseRank() {
        let runningOld = make(phase: .running, lastActivity: Date(timeIntervalSince1970: 100))
        let waitingNew = make(phase: .waiting, lastActivity: Date(timeIntervalSince1970: 999))
        XCTAssertTrue(runningOld < waitingNew, "Phase rank beats recency across different phases")
    }
}
