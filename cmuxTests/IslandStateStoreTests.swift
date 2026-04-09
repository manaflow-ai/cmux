// cmuxTests/IslandStateStoreTests.swift

import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class IslandStateStoreTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    private func makeSession(
        phase: IslandSessionPhase = .running,
        kind: IslandAgentKind = .claudeCode,
        lastActivity: Date = Date(timeIntervalSince1970: 100),
        unread: Int = 0
    ) -> IslandSession {
        IslandSession(
            id: UUID(),
            workspaceId: UUID(),
            panelId: UUID(),
            agentKind: kind,
            phase: phase,
            workspaceTitle: "ws",
            panelTitle: "p",
            lastActivity: lastActivity,
            unreadCount: unread,
            rawStatusValue: phase.rawValue
        )
    }

    func testEmptySourceEmitsEmptyList() {
        let source = InMemoryIslandStateSource()
        let store = IslandStateStore(source: source)
        XCTAssertEqual(store.currentSessions, [])
    }

    func testSingleSessionIsEmittedAfterDebounce() {
        let source = InMemoryIslandStateSource()
        let store = IslandStateStore(source: source)

        var received: [[IslandSession]] = []
        let exp = expectation(description: "emit after source change")
        exp.expectedFulfillmentCount = 1

        store.sessionsPublisher
            .dropFirst()  // skip initial empty snapshot
            .sink { sessions in
                received.append(sessions)
                exp.fulfill()
            }
            .store(in: &cancellables)

        let s = makeSession()
        source.set([s])

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(received.last?.count, 1)
        XCTAssertEqual(received.last?.first?.id, s.id)
    }

    func testSortOrderRunningBeforeIdle() {
        let source = InMemoryIslandStateSource()
        let idle    = makeSession(phase: .idle)
        let running = makeSession(phase: .running)
        source.set([idle, running])
        let store = IslandStateStore(source: source)

        XCTAssertEqual(store.currentSessions.map(\.phase), [.running, .idle])
    }

    func testClearingSourceEmitsEmpty() {
        let source = InMemoryIslandStateSource()
        source.set([makeSession()])
        let store = IslandStateStore(source: source)
        XCTAssertEqual(store.currentSessions.count, 1)

        let exp = expectation(description: "empty emission after clear")

        store.sessionsPublisher
            .dropFirst()
            .sink { sessions in
                if sessions.isEmpty {
                    exp.fulfill()
                }
            }
            .store(in: &cancellables)

        source.clear()
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(store.currentSessions, [])
    }
}
