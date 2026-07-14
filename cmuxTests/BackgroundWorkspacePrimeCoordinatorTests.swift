import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BackgroundWorkspacePrimeCoordinatorTests {
    @Test
    func timeoutAdvancesSequentiallyAndCancellationStopsThePass() async {
        let first = UUID()
        let second = UUID()
        let timeout = ManualPrimeTimeout()
        let host = FakeBackgroundWorkspacePrimeHost(
            pendingWorkspaceIDs: [first, second],
            states: [first: .needsSurfaceStart, second: .needsSurfaceStart]
        )
        let coordinator = BackgroundWorkspacePrimeCoordinator(timeoutSleep: timeout.sleep)

        let task = Task {
            await coordinator.primePendingBackgroundWorkspaces(host: host)
        }
        await host.waitForRequestCount(1, workspaceID: first)

        timeout.fire()
        await host.waitForRequestCount(1, workspaceID: second)

        task.cancel()
        await task.value

        #expect(host.pendingBackgroundWorkspaceLoadIds == [first, second])
    }

    @Test
    func readinessCompletionClearsPendingState() async {
        let workspaceID = UUID()
        let host = FakeBackgroundWorkspacePrimeHost(
            pendingWorkspaceIDs: [workspaceID],
            states: [workspaceID: .needsSurfaceStart]
        )
        host.stateAfterRequest[workspaceID] = .ready
        let coordinator = BackgroundWorkspacePrimeCoordinator()

        await coordinator.primePendingBackgroundWorkspaces(host: host)

        #expect(host.requestCount(for: workspaceID) == 1)
        #expect(host.pendingBackgroundWorkspaceLoadIds.isEmpty)
    }

    @Test
    func removedWorkspaceClearsPendingState() async {
        let workspaceID = UUID()
        let host = FakeBackgroundWorkspacePrimeHost(
            pendingWorkspaceIDs: [workspaceID],
            states: [workspaceID: .workspaceRemoved]
        )
        let coordinator = BackgroundWorkspacePrimeCoordinator()

        await coordinator.primePendingBackgroundWorkspaces(host: host)

        #expect(host.pendingBackgroundWorkspaceLoadIds.isEmpty)
    }
}

private final class ManualPrimeTimeout: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func sleep() async throws {
        for await _ in stream {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }

    func fire() {
        continuation.yield(())
    }
}

@MainActor
private final class FakeBackgroundWorkspacePrimeHost: BackgroundWorkspacePrimeHosting {
    private struct RequestWaiter {
        let workspaceID: UUID
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let pendingSubject: CurrentValueSubject<Set<UUID>, Never>
    private let workspaceIDsSubject: CurrentValueSubject<Set<UUID>, Never>
    private var requestCounts: [UUID: Int] = [:]
    private var requestWaiters: [RequestWaiter] = []

    var states: [UUID: BackgroundWorkspacePrimeWorkState]
    var stateAfterRequest: [UUID: BackgroundWorkspacePrimeWorkState] = [:]

    var pendingBackgroundWorkspaceLoadIds: Set<UUID> { pendingSubject.value }

    var backgroundWorkspacePrimePendingPublisher: AnyPublisher<Set<UUID>, Never> {
        pendingSubject.eraseToAnyPublisher()
    }

    var backgroundWorkspacePrimeWorkspaceIDsPublisher: AnyPublisher<Set<UUID>, Never> {
        workspaceIDsSubject.eraseToAnyPublisher()
    }

    init(
        pendingWorkspaceIDs: Set<UUID>,
        states: [UUID: BackgroundWorkspacePrimeWorkState]
    ) {
        pendingSubject = CurrentValueSubject(pendingWorkspaceIDs)
        workspaceIDsSubject = CurrentValueSubject(Set(states.keys))
        self.states = states
    }

    func backgroundWorkspacePrimeWorkState(for workspaceID: UUID) -> BackgroundWorkspacePrimeWorkState {
        states[workspaceID] ?? .workspaceRemoved
    }

    func requestBackgroundWorkspacePrimeSurfaceStart(for workspaceID: UUID) {
        requestCounts[workspaceID, default: 0] += 1
        if let nextState = stateAfterRequest[workspaceID] {
            states[workspaceID] = nextState
        }
        resumeSatisfiedRequestWaiters()
    }

    func completeBackgroundWorkspaceLoad(for workspaceID: UUID) {
        var pending = pendingSubject.value
        pending.remove(workspaceID)
        pendingSubject.send(pending)
    }

    func requestCount(for workspaceID: UUID) -> Int {
        requestCounts[workspaceID, default: 0]
    }

    func waitForRequestCount(_ count: Int, workspaceID: UUID) async {
        guard requestCount(for: workspaceID) < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(
                RequestWaiter(workspaceID: workspaceID, count: count, continuation: continuation)
            )
        }
    }

    private func resumeSatisfiedRequestWaiters() {
        var remaining: [RequestWaiter] = []
        for waiter in requestWaiters {
            if requestCount(for: waiter.workspaceID) >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestWaiters = remaining
    }
}
