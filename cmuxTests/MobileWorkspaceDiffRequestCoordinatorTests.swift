import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct MobileWorkspaceDiffRequestCoordinatorTests {
    @Test func replacesPendingRequestWhileActiveWorkIsStalled() async throws {
        let coordinator = MobileWorkspaceDiffRequestCoordinator()
        let activeStarted = CoordinatorTestSignal()
        let activeCancelled = CoordinatorTestSignal()
        let activeGate = MobileWorkspaceDiffOperationGate()
        let secondFinished = CoordinatorTestSignal()

        let first = Task {
            await coordinator.perform {
                await withTaskCancellationHandler {
                    activeStarted.fulfill()
                    await activeGate.wait()
                    return .ok(["request": "first"])
                } onCancel: {
                    activeCancelled.fulfill()
                }
            }
        }
        try await activeStarted.wait()

        let second = Task {
            let result = await coordinator.perform {
                .ok(["request": "second"])
            }
            secondFinished.fulfill()
            return result
        }
        try await activeCancelled.wait()

        let thirdSubmitted = CoordinatorTestSignal()
        let third = Task {
            thirdSubmitted.fulfill()
            return await coordinator.perform {
                .ok(["request": "third"])
            }
        }
        try await thirdSubmitted.wait()

        let supersededFinishedBeforeActiveRelease: Bool
        do {
            try await secondFinished.wait()
            supersededFinishedBeforeActiveRelease = true
        } catch {
            supersededFinishedBeforeActiveRelease = false
        }

        await activeGate.release()
        _ = await first.value
        let secondResult = await second.value
        let thirdResult = await third.value

        #expect(
            supersededFinishedBeforeActiveRelease,
            "A replaced pending request must finish while cancelled active work is still stalled"
        )
        guard case let .failure(secondError) = secondResult else {
            Issue.record("The replaced pending request did not return cancellation")
            return
        }
        #expect(secondError.code == "cancelled")
        guard case let .ok(thirdPayload) = thirdResult,
              let thirdDictionary = thirdPayload as? [String: String] else {
            Issue.record("The newest pending request did not run after active work stopped")
            return
        }
        #expect(thirdDictionary["request"] == "third")
    }
}

private final class CoordinatorTestSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var fulfilled = false

    func fulfill() {
        condition.lock()
        fulfilled = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() async throws {
        try await Task.detached { [self] in
            try blockingWait()
        }.value
    }

    private func blockingWait() throws {
        let deadline = Date().addingTimeInterval(1)
        condition.lock()
        defer { condition.unlock() }
        while !fulfilled {
            if !condition.wait(until: deadline) {
                throw CoordinatorTestTimeout()
            }
        }
    }
}

private struct CoordinatorTestTimeout: Error {}

private actor MobileWorkspaceDiffOperationGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}
