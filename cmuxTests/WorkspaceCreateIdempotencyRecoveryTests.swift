import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct WorkspaceCreateIdempotencyRecoveryTests {
    @Test func transientInitialLoadFailureRetriesBeforeAccepting() throws {
        let operationID = UUID()
        let persistence = TransientLoadFailurePersistence()
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 8,
            persistence: persistence
        )

        try cache.accept(operationID: operationID)

        #expect(persistence.loadCount == 2)
        #expect(persistence.savedOperationIDs == [operationID])
        #expect(cache.containsCompletedOperation(operationID))
    }

    @Test func asynchronousAcceptPersistsOffTheMainThread() async throws {
        let persistence = TransientLoadFailurePersistence(failFirstLoad: false)
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 8,
            persistence: persistence
        )

        #expect(try await cache.acceptAsynchronously(operationID: UUID()))
        #expect(persistence.saveWasOnMainThread == false)
    }

    @Test func restoredRecordDuringPendingAcceptanceIsMergedAndRepersisted() async throws {
        let acceptedOperationID = UUID()
        let restoredOperationID = UUID()
        let workspaceID = UUID()
        let persistence = BlockingFirstSavePersistence()
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 8,
            persistence: persistence
        )

        let acceptance = Task {
            try await cache.acceptAsynchronously(operationID: acceptedOperationID)
        }
        await persistence.waitForFirstSaveToStart()
        cache.record(operationID: restoredOperationID, workspaceID: workspaceID)
        persistence.releaseFirstSave()

        #expect(try await acceptance.value)
        #expect(persistence.savedOperationIDs == [restoredOperationID, acceptedOperationID])
        #expect(cache.containsCompletedOperation(restoredOperationID))
        #expect(cache.containsCompletedOperation(acceptedOperationID))
        #expect(cache.workspaceID(for: restoredOperationID) == workspaceID)
    }

    @Test func releasedAcceptanceAtCapacityRestoresEvictedTombstone() async throws {
        let firstCompletedOperationID = UUID()
        let secondCompletedOperationID = UUID()
        let releasedOperationID = UUID()
        let persistence = TransientLoadFailurePersistence(failFirstLoad: false)
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 2,
            persistence: persistence
        )

        try cache.accept(operationID: firstCompletedOperationID)
        try cache.accept(operationID: secondCompletedOperationID)
        #expect(try await cache.acceptAsynchronously(operationID: releasedOperationID))
        #expect(cache.containsCompletedOperation(firstCompletedOperationID) == false)

        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: releasedOperationID
            )
        )

        #expect(cache.containsCompletedOperation(firstCompletedOperationID))
        #expect(cache.containsCompletedOperation(secondCompletedOperationID))
        #expect(cache.containsCompletedOperation(releasedOperationID) == false)
        #expect(persistence.savedOperationIDs == [
            firstCompletedOperationID,
            secondCompletedOperationID,
        ])
    }

    @Test func outOfOrderReleasesPreserveRestoredTombstoneChronology() async throws {
        let firstCompletedOperationID = UUID()
        let secondCompletedOperationID = UUID()
        let firstReservationID = UUID()
        let secondReservationID = UUID()
        let laterOperationID = UUID()
        let persistence = TransientLoadFailurePersistence(failFirstLoad: false)
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 2,
            persistence: persistence
        )

        try cache.accept(operationID: firstCompletedOperationID)
        try cache.accept(operationID: secondCompletedOperationID)
        #expect(try await cache.acceptAsynchronously(operationID: firstReservationID))
        #expect(try await cache.acceptAsynchronously(operationID: secondReservationID))

        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: firstReservationID
            )
        )
        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: secondReservationID
            )
        )
        #expect(persistence.savedOperationIDs == [
            firstCompletedOperationID,
            secondCompletedOperationID,
        ])

        try cache.accept(operationID: laterOperationID)

        #expect(!cache.containsCompletedOperation(firstCompletedOperationID))
        #expect(cache.containsCompletedOperation(secondCompletedOperationID))
        #expect(cache.containsCompletedOperation(laterOperationID))
        #expect(persistence.savedOperationIDs == [
            secondCompletedOperationID,
            laterOperationID,
        ])
    }

    @Test func nestedReleasesRestoreTheOriginalTombstone() async throws {
        let originalOperationID = UUID()
        let firstReservationID = UUID()
        let secondReservationID = UUID()
        let persistence = TransientLoadFailurePersistence(failFirstLoad: false)
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 1,
            persistence: persistence
        )

        try cache.accept(operationID: originalOperationID)
        #expect(try await cache.acceptAsynchronously(operationID: firstReservationID))
        #expect(try await cache.acceptAsynchronously(operationID: secondReservationID))

        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: secondReservationID
            )
        )
        #expect(cache.containsCompletedOperation(firstReservationID))
        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: firstReservationID
            )
        )

        #expect(cache.containsCompletedOperation(originalOperationID))
        #expect(cache.containsCompletedOperation(firstReservationID) == false)
        #expect(cache.containsCompletedOperation(secondReservationID) == false)
        #expect(persistence.savedOperationIDs == [originalOperationID])
    }

    @Test func releasingEvictedReservationCannotResurrectIt() async throws {
        let originalOperationID = UUID()
        let firstReservationID = UUID()
        let secondReservationID = UUID()
        let persistence = TransientLoadFailurePersistence(failFirstLoad: false)
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 1,
            persistence: persistence
        )

        try cache.accept(operationID: originalOperationID)
        #expect(try await cache.acceptAsynchronously(operationID: firstReservationID))
        #expect(try await cache.acceptAsynchronously(operationID: secondReservationID))

        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: firstReservationID
            )
        )
        #expect(
            try await cache.releaseUnassociatedAcceptanceAsynchronously(
                operationID: secondReservationID
            )
        )

        #expect(cache.containsCompletedOperation(originalOperationID))
        #expect(cache.containsCompletedOperation(firstReservationID) == false)
        #expect(cache.containsCompletedOperation(secondReservationID) == false)
        #expect(persistence.savedOperationIDs == [originalOperationID])
        #expect(try await cache.acceptAsynchronously(operationID: firstReservationID))
    }
}

private final class TransientLoadFailurePersistence:
    TerminalController.WorkspaceCreateIdempotencyPersisting, @unchecked Sendable
{
    private let failFirstLoad: Bool
    private(set) var loadCount = 0
    private(set) var savedOperationIDs: [UUID] = []
    private(set) var saveWasOnMainThread: Bool?

    init(failFirstLoad: Bool = true) {
        self.failFirstLoad = failFirstLoad
    }

    func loadOperationIDs() throws -> [UUID] {
        loadCount += 1
        if failFirstLoad, loadCount == 1 { throw TransientLoadFailure.injected }
        return []
    }

    func saveOperationIDs(_ operationIDs: [UUID]) {
        saveWasOnMainThread = Thread.isMainThread
        savedOperationIDs = operationIDs
    }
}

private enum TransientLoadFailure: Error {
    case injected
}

final class BlockingFirstSavePersistence:
    TerminalController.WorkspaceCreateIdempotencyPersisting, @unchecked Sendable
{
    private let firstSaveStarted = DispatchSemaphore(value: 0)
    private let releaseFirstSaveSemaphore = DispatchSemaphore(value: 0)
    private let savedOperationIDsLock = NSLock()
    private var storedOperationIDs: [UUID] = []
    private var saveCount = 0

    var savedOperationIDs: [UUID] {
        savedOperationIDsLock.withLock { storedOperationIDs }
    }

    func loadOperationIDs() -> [UUID] { [] }

    func saveOperationIDs(_ operationIDs: [UUID]) {
        let shouldBlock = savedOperationIDsLock.withLock {
            saveCount += 1
            return saveCount == 1
        }
        if shouldBlock {
            firstSaveStarted.signal()
            releaseFirstSaveSemaphore.wait()
        }
        savedOperationIDsLock.withLock {
            storedOperationIDs = operationIDs
        }
    }

    func waitForFirstSaveToStart() async {
        await Task.detached { [firstSaveStarted] in
            firstSaveStarted.wait()
        }.value
    }

    func releaseFirstSave() {
        releaseFirstSaveSemaphore.signal()
    }
}
