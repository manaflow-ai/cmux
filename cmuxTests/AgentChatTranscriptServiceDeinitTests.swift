import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `AgentChatTranscriptService` is owned by `AppDelegate`, whose session
/// autosave write block retains the delegate on the utility
/// `com.cmuxterm.app.sessionPersistence` queue. When that block is released
/// after it runs, the delegate — and this service with it — deinit on that
/// queue. A `deinit` is nonisolated, so it must not assume the main actor:
/// `MainActor.assumeIsolated` there is a `dispatch_assert_queue` trap that
/// takes the whole app-host test process down mid-batch (every suite still in
/// flight is then reported as red).
struct AgentChatTranscriptServiceDeinitTests {
    @MainActor
    @Test func releasingTheServiceOffTheMainActorDoesNotTrap() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-transcript-service-deinit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let queue = DispatchQueue(label: "cmux.tests.transcript-service-release")
        let gate = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)

        // The service is a temporary: once `retainOnQueue` returns, the queue
        // block holds the only reference, and libdispatch destroys the block —
        // and with it the service — on the queue right after the block
        // returns, exactly like the delegate's autosave write block.
        Self.retainOnQueue(
            AgentChatTranscriptService(
                registry: AgentChatSessionRegistry(),
                resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
                hasEventSubscribers: { false },
                emitEventPayload: { _ in }
            ),
            queue: queue,
            gate: gate
        )
        gate.signal()
        queue.async { released.signal() }

        #expect(released.wait(timeout: .now() + 5) == .success)
        // The teardown the service defers to the main actor runs on the next
        // turn; give it that turn so a trap there would surface in this test.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private static func retainOnQueue(
        _ service: AgentChatTranscriptService,
        queue: DispatchQueue,
        gate: DispatchSemaphore
    ) {
        nonisolated(unsafe) let retained = service
        queue.async {
            gate.wait()
            _ = retained
        }
    }
}
