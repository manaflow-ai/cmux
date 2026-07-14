import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateReviewRegressionTests {
    @Test func oversizedWorkingDirectoryIsRejectedBeforeClassification() async {
        let classifierCalls = LockedInvocationCount()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 1,
            maximumPendingWaiters: 4,
            laneClassifier: { _ in
                classifierCalls.increment()
                return .local
            },
            probe: { _, _ in true },
            sleepUntilDeadline: { _ in }
        )

        let result = await service.validate(
            rawValue: "/" + String(repeating: "a", count: 4_097),
            isProvided: true
        )

        #expect(result == .invalid)
        #expect(classifierCalls.value == 0)
    }

    @Test func invalidMobileRequestDoesNotConsumeOperationID() async {
        let suiteName = "WorkspaceCreateReviewRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 16,
            defaults: defaults,
            persistenceKey: "completed"
        )
        let manager = TabManager()
        let baselineCount = manager.tabs.count
        let operationID = UUID()

        let invalid = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "layout": Date(),
            ],
            tabManager: manager,
            idempotencyCache: cache
        )

        #expect(Self.errorCode(invalid) == "invalid_params")
        #expect(cache.containsCompletedOperation(operationID) == false)
        #expect(manager.tabs.count == baselineCount)

        let retry = await TerminalController.shared.v2MobileWorkspaceCreate(
            params: ["operation_id": operationID.uuidString],
            tabManager: manager,
            idempotencyCache: cache
        )

        #expect(Self.errorCode(retry) == nil)
        #expect(cache.containsCompletedOperation(operationID))
        #expect(manager.tabs.count == baselineCount + 1)
    }

    private static func errorCode(_ result: TerminalController.V2CallResult) -> String? {
        guard case let .err(code, _, _) = result else { return nil }
        return code
    }
}

private final class LockedInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
