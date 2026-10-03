import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud terminal projection registry")
struct CloudTerminalProjectionRegistryTests {
    @Test @MainActor
    func cancellingOneWaiterDoesNotCancelTheSharedProjection() async throws {
        let gate = ProjectionTestGate()
        let projection = CloudTerminalProjectionTask<Int> {
            await gate.wait()
            return 42
        }
        let firstOutcome = ProjectionTestOutcome()
        let first = Task { @MainActor in
            try await projection.wait()
        }
        let firstObserver = Task { @MainActor in
            do {
                _ = try await first.value
                firstOutcome.recordSuccess()
            } catch {
                firstOutcome.record(error: error)
            }
        }

        try await waitUntil { await gate.waiterCount == 1 }
        first.cancel()
        try await waitUntil { firstOutcome.sawCancellation }
        #expect(await gate.waiterCount == 1)

        let second = Task { @MainActor in
            try await projection.wait()
        }
        gate.release()
        #expect(try await second.value == 42)
        _ = await firstObserver.result
    }

    @Test @MainActor
    func lateCompletionFromAStoppedProjectionCannotRemoveItsReplacement() async throws {
        let oldGate = ProjectionTestGate()
        let newGate = ProjectionTestGate()
        let registry = CloudTerminalProjectionRegistry<Int>()
        let oldOutcome = ProjectionTestOutcome()
        let old = Task { @MainActor in
            try await registry.value(for: "socket\0terminal") {
                await oldGate.wait()
                return 1
            }
        }
        let oldObserver = Task { @MainActor in
            do {
                _ = try await old.value
                oldOutcome.recordSuccess()
            } catch {
                oldOutcome.record(error: error)
            }
        }
        try await waitUntil { await oldGate.waiterCount == 1 }

        let retiredCleanup = registry.cancelAll()
        try await waitUntil { oldOutcome.sawCancellation }

        let replacement = Task { @MainActor in
            try await registry.value(for: "socket\0terminal") {
                await newGate.wait()
                return 2
            }
        }
        try await waitUntil { await newGate.waiterCount == 1 }

        // The old operation ignores cancellation and completes after teardown.
        // Its cleanup must not remove the replacement entry.
        oldGate.release()
        await retiredCleanup.value
        #expect(await registry.contains("socket\0terminal"))

        newGate.release()
        #expect(try await replacement.value == 2)
        _ = await oldObserver.result
        try await waitUntil { await registry.isEmpty }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition(), "Timed out waiting for projection state")
    }
}

@MainActor
private final class ProjectionTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class ProjectionTestOutcome {
    private(set) var sawCancellation = false

    func recordSuccess() {
        sawCancellation = false
    }

    func record(error: Error) {
        sawCancellation = error is CancellationError
    }
}
