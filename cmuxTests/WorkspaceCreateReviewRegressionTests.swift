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

    @Test func blockedClassificationTimesOutWithoutBlockingServiceActor() async {
        let classifier = ControlledPathClassifier()
        let deadlines = ControlledReviewDeadlines()
        let service = TerminalController.WorkspaceCreateWorkingDirectoryValidationService(
            timeout: .seconds(1),
            localCapacity: 1,
            externalCapacity: 1,
            classificationCapacity: 1,
            maximumPendingWaiters: 4,
            laneClassifier: { path in await classifier.classify(path) },
            probe: { _, _ in true },
            sleepUntilDeadline: { _ in await deadlines.suspendUntilFired() }
        )
        let first = Task { await service.validate(rawValue: "/tmp/first", isProvided: true) }
        await classifier.waitForCount(1)
        await deadlines.waitForCount(1)
        await deadlines.fireAll()
        #expect(await first.value == .timedOut)

        let second = Task { await service.validate(rawValue: "/tmp/second", isProvided: true) }
        await deadlines.waitForCount(2)
        await deadlines.fireAll()
        #expect(await second.value == .timedOut)
        #expect(await classifier.count == 1)
        await classifier.complete()
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

private actor ControlledPathClassifier {
    private(set) var count = 0
    private var continuation: CheckedContinuation<
        TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane,
        Never
    >?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func classify(
        _ path: String
    ) async -> TerminalController.WorkspaceCreateWorkingDirectoryValidationService.ProbeLane {
        _ = path
        count += 1
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func complete() {
        continuation?.resume(returning: .local)
        continuation = nil
    }
}

private actor ControlledReviewDeadlines {
    private var count = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func suspendUntilFired() async {
        count += 1
        let ready = countWaiters.filter { count >= $0.0 }
        countWaiters.removeAll { count >= $0.0 }
        for waiter in ready { waiter.1.resume() }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { countWaiters.append((expected, $0)) }
    }

    func fireAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
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
