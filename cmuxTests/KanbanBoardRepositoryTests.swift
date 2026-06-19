import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct KanbanBoardRepositoryTests {
    /// A fixed instant (no sub-second component) so `.iso8601` round-trips exactly.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KanbanBoardRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test
    func loadReturnsEmptyBoardWhenFileMissing() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        let board = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)

        #expect(board.workspaceId == workspaceId)
        #expect(board.cards.isEmpty)
        #expect(board.wipLimit == 2)
        #expect(board.ripping == false)
        #expect(board.schemaVersion == KanbanBoard.currentSchemaVersion)
    }

    @Test
    func saveThenLoadRoundTripsBoardWithCards() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        let card = KanbanCard(
            title: "Fix the login bug",
            detail: "Reproduce, root-cause, patch, add regression test.",
            column: .ready,
            backendKind: .cmux,
            agentProvider: .claude,
            createdAt: Self.fixedNow,
            updatedAt: Self.fixedNow
        )
        let board = KanbanBoard(
            workspaceId: workspaceId,
            wipLimit: 3,
            ripping: true,
            testCommand: "bun test",
            cards: [card],
            updatedAt: Self.fixedNow
        )

        try await repo.save(board)
        let loaded = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)

        #expect(loaded == board)
        #expect(loaded.cards.count == 1)
        #expect(loaded.cards[0].title == "Fix the login bug")
        #expect(loaded.cards[0].agentProvider == .claude)
        #expect(loaded.testCommand == "bun test")
    }

    @Test
    func loadThrowsOnCorruptedBoardFile() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let workspaceId = UUID()

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("{ not valid json ".utf8).write(to: await repo.boardURL(workspaceId: workspaceId))

        await #expect(throws: KanbanBoardRepositoryError.corruptedBoardFile(workspaceId: workspaceId)) {
            _ = try await repo.load(workspaceId: workspaceId, now: Self.fixedNow)
        }
    }

    @Test
    func appendLogAccumulatesAcrossCalls() async throws {
        let base = makeTempBaseDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = KanbanBoardRepository(baseDirectory: base)
        let cardId = UUID()

        try await repo.appendLog(cardId: cardId, text: "line one\n")
        try await repo.appendLog(cardId: cardId, text: "line two\n")

        let contents = try String(contentsOf: await repo.logURL(cardId: cardId), encoding: .utf8)
        #expect(contents == "line one\nline two\n")
    }
}

@Suite
struct KanbanBoardModelTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let later = Date(timeIntervalSince1970: 1_700_000_100)

    @Test
    func upsertingInsertsThenReplacesById() {
        let id = UUID()
        var board = KanbanBoard.empty(workspaceId: UUID(), now: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "First", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        #expect(board.cards.count == 1)

        board = board.upserting(
            KanbanCard(id: id, title: "Renamed", createdAt: Self.now, updatedAt: Self.now),
            now: Self.later
        )
        #expect(board.cards.count == 1)
        #expect(board.cards[0].title == "Renamed")
        #expect(board.cards[0].updatedAt == Self.later)
    }

    @Test
    func movingCardUpdatesColumnAndWipCount() {
        let id = UUID()
        var board = KanbanBoard.empty(workspaceId: UUID(), now: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "Task", column: .ready, createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        #expect(board.wipInUse == 0)

        board = board.movingCard(id: id, to: .building, now: Self.later)
        #expect(board.cards(in: .building).count == 1)
        #expect(board.wipInUse == 1)
    }

    @Test
    func reconcileRequeuesInFlightCardsWhenRipping() {
        let buildingId = UUID()
        let testingId = UUID()
        var board = KanbanBoard(workspaceId: UUID(), ripping: true, updatedAt: Self.now)
        board = board.upserting(
            KanbanCard(id: buildingId, title: "A", column: .building, sessionId: "s1", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )
        board = board.upserting(
            KanbanCard(id: testingId, title: "B", column: .testing, sessionId: "s2", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )

        let reconciled = board.reconcilingOrphansAfterRelaunch(now: Self.later)
        #expect(reconciled.cards(in: .ready).count == 2)
        #expect(reconciled.cards.allSatisfy { $0.sessionId == nil })
    }

    @Test
    func reconcileFailsInFlightCardsWhenNotRipping() {
        let id = UUID()
        var board = KanbanBoard(workspaceId: UUID(), ripping: false, updatedAt: Self.now)
        board = board.upserting(
            KanbanCard(id: id, title: "A", column: .building, sessionId: "s1", createdAt: Self.now, updatedAt: Self.now),
            now: Self.now
        )

        let reconciled = board.reconcilingOrphansAfterRelaunch(now: Self.later)
        #expect(reconciled.cards(in: .failed).count == 1)
        #expect(reconciled.cards(in: .ready).isEmpty)
    }

    @Test
    func unknownColumnDecodesToBacklog() throws {
        let json = Data(#"{"column":"warp-core-breach"}"#.utf8)
        struct Holder: Codable { let column: KanbanColumn }
        let holder = try JSONDecoder().decode(Holder.self, from: json)
        #expect(holder.column == .backlog)
    }
}
