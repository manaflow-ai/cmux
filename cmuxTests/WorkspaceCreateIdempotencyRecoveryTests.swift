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
}

private final class TransientLoadFailurePersistence:
    TerminalController.WorkspaceCreateIdempotencyPersisting
{
    private(set) var loadCount = 0
    private(set) var savedOperationIDs: [UUID] = []

    func loadOperationIDs() throws -> [UUID] {
        loadCount += 1
        if loadCount == 1 { throw TransientLoadFailure.injected }
        return []
    }

    func saveOperationIDs(_ operationIDs: [UUID]) {
        savedOperationIDs = operationIDs
    }
}

private enum TransientLoadFailure: Error {
    case injected
}
