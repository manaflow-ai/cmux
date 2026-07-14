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
