import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The socket handlers and session restore mutate the idempotency cache
/// synchronously on the main thread, so its asynchronous accept must not touch
/// that state until the main actor is free. When the async methods ran on the
/// global executor instead, they raced those mutations and crashed the app host
/// in `concurrentMobileRequestsWithSameOperationCreateExactlyOnce`.
@MainActor
@Suite struct WorkspaceCreateIdempotencyIsolationTests {
    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(1)))
    func asynchronousAcceptWaitsForTheMainActor() async throws {
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 8,
            persistence: InMemoryWorkspaceCreateIdempotencyStore()
        )
        let executor = JobCompletionSignalingExecutor()
        let accepting = acceptOffTheMainActor(cache, preferring: executor)

        // Hold the main actor until the caller's first job returns. An
        // unisolated accept runs inline on that job and claims the mutation
        // slot before suspending; an isolated one can only hop to the main
        // actor. Either way the job returns without needing the main thread.
        try #require(executor.waitForFinishedJob(), "The off-main caller never ran")
        try cache.accept(operationID: UUID())

        #expect(try await accepting.value)
    }
}

/// Starts the accept from a nonisolated context so the task's first job runs on
/// the preferred executor rather than inheriting the test's main actor.
@available(macOS 15.0, *)
private func acceptOffTheMainActor(
    _ cache: TerminalController.WorkspaceCreateIdempotencyCache,
    preferring executor: JobCompletionSignalingExecutor
) -> Task<Bool, any Error> {
    Task(executorPreference: executor) {
        try await cache.acceptAsynchronously(operationID: UUID())
    }
}

/// Reports each job only after it runs to its next suspension, never on a timer.
@available(macOS 15.0, *)
private final class JobCompletionSignalingExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "cmux.tests.workspace-create-idempotency-executor")
    private let jobFinished = DispatchSemaphore(value: 0)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
            jobFinished.signal()
        }
    }

    /// Blocks the calling thread, so a main-actor caller keeps the main actor.
    func waitForFinishedJob() -> Bool {
        jobFinished.wait(timeout: .now() + .seconds(30)) == .success
    }
}
