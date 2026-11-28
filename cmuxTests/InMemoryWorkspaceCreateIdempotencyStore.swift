import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class InMemoryWorkspaceCreateIdempotencyStore:
    TerminalController.WorkspaceCreateIdempotencyPersisting {
    private var operationIDs: [UUID] = []

    func loadOperationIDs() -> [UUID] { operationIDs }

    func saveOperationIDs(_ operationIDs: [UUID]) {
        self.operationIDs = operationIDs
    }
}
