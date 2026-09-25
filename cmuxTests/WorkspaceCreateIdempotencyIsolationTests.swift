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
    @Test func asynchronousAcceptWaitsForTheMainActor() async throws {
        let cache = TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: 8,
            persistence: InMemoryWorkspaceCreateIdempotencyStore()
        )
        let callerStarted = DispatchSemaphore(value: 0)
        let accepting = Task.detached {
            callerStarted.signal()
            return try await cache.acceptAsynchronously(operationID: UUID())
        }

        // Hold the main actor while the off-main caller runs. The pause only
        // gives an unisolated accept time to claim the mutation slot; an
        // isolated one cannot start until this test suspends below, so the
        // synchronous accept never finds a mutation in flight.
        callerStarted.wait()
        Thread.sleep(forTimeInterval: 0.25)
        try cache.accept(operationID: UUID())

        #expect(try await accepting.value)
    }
}
