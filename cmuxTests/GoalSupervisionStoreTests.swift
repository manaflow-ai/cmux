import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GoalSupervisionStoreTests: XCTestCase {
    func testInitialLoadSortsActiveGoalsFirstThenUpdatedAt() async throws {
        let fileURL = try makeTemporaryGoalsFileURL()
        defer { removeTemporaryContainer(for: fileURL) }

        let persistence = GoalSupervisionPersistence(fileURL: fileURL)
        let activeOlder = makeRecord(
            title: "Active older",
            status: .active,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let pausedNewer = makeRecord(
            title: "Paused newer",
            status: .paused,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await persistence.save([pausedNewer, activeOlder])

        let store = GoalSupervisionStore(persistence: persistence)
        await store.waitForInitialLoad()

        XCTAssertEqual(store.snapshots().map(\.id), [activeOlder.id, pausedNewer.id])
    }

    func testCreateGoalNormalizesAndPersistsGoal() async throws {
        let fileURL = try makeTemporaryGoalsFileURL()
        defer { removeTemporaryContainer(for: fileURL) }

        let persistence = GoalSupervisionPersistence(fileURL: fileURL)
        let store = GoalSupervisionStore(persistence: persistence)
        await store.waitForInitialLoad()

        let id = try XCTUnwrap(store.createGoal(
            title: "  Ship Goals  ",
            acceptanceCriteria: "  Track persisted status  ",
            workspacePath: "  /tmp/cmux-goals  "
        ))
        await store.waitForPendingSave()

        let loaded = try await persistence.load()
        let persisted = try XCTUnwrap(loaded.first { $0.id == id })
        XCTAssertEqual(persisted.title, "Ship Goals")
        XCTAssertEqual(persisted.acceptanceCriteria, "Track persisted status")
        XCTAssertEqual(persisted.workspacePath, "/tmp/cmux-goals")
        XCTAssertEqual(persisted.status, .active)
    }

    func testNoOpStatusUpdateDoesNotRewriteUpdatedAt() async throws {
        let fileURL = try makeTemporaryGoalsFileURL()
        defer { removeTemporaryContainer(for: fileURL) }

        let persistence = GoalSupervisionPersistence(fileURL: fileURL)
        let store = GoalSupervisionStore(persistence: persistence)
        await store.waitForInitialLoad()

        let id = try XCTUnwrap(store.createGoal(
            title: "Status stability",
            acceptanceCriteria: "",
            workspacePath: nil
        ))
        store.updateStatus(for: id, status: .paused)
        let paused = try XCTUnwrap(store.snapshots().first { $0.id == id })

        store.updateStatus(for: id, status: .paused)
        let unchanged = try XCTUnwrap(store.snapshots().first { $0.id == id })

        XCTAssertEqual(unchanged.status, .paused)
        XCTAssertEqual(unchanged.updatedAt, paused.updatedAt)
        XCTAssertEqual(unchanged.accumulatedActiveSeconds, paused.accumulatedActiveSeconds)
        await store.waitForPendingSave()
    }

    func testLoadFailureUsesUserFacingErrorMessage() async throws {
        let fileURL = try makeTemporaryGoalsFileURL()
        defer { removeTemporaryContainer(for: fileURL) }
        try Data("not json".utf8).write(to: fileURL)

        let store = GoalSupervisionStore(persistence: GoalSupervisionPersistence(fileURL: fileURL))
        await store.waitForInitialLoad()

        XCTAssertEqual(store.lastError, GoalSupervisionStore.loadFailureMessage)
        XCTAssertTrue(store.snapshots().isEmpty)
    }

    func testSaveFailureUsesUserFacingErrorMessage() async throws {
        let directoryURL = try makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let blockingFileURL = directoryURL.appendingPathComponent("goals-parent", isDirectory: false)
        _ = FileManager.default.createFile(atPath: blockingFileURL.path, contents: Data())
        let fileURL = blockingFileURL.appendingPathComponent("goals.json", isDirectory: false)
        let store = GoalSupervisionStore(persistence: GoalSupervisionPersistence(fileURL: fileURL))
        await store.waitForInitialLoad()

        XCTAssertNotNil(store.createGoal(title: "Save error", acceptanceCriteria: "", workspacePath: nil))
        await store.waitForPendingSave()

        XCTAssertEqual(store.lastError, GoalSupervisionStore.saveFailureMessage)
    }

    private func makeRecord(
        title: String,
        status: GoalSupervisionStatus,
        updatedAt: Date
    ) -> GoalSupervisionRecord {
        GoalSupervisionRecord(
            id: UUID(),
            title: title,
            acceptanceCriteria: "",
            workspacePath: nil,
            status: status,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: updatedAt,
            activeSince: status == .active ? updatedAt : nil,
            accumulatedActiveSeconds: 0,
            notes: []
        )
    }

    private func makeTemporaryGoalsFileURL() throws -> URL {
        try makeTemporaryDirectoryURL().appendingPathComponent("goals.json", isDirectory: false)
    }

    private func makeTemporaryDirectoryURL() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-goals-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func removeTemporaryContainer(for fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}
