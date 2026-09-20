import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatTranscriptServiceOffMainReleaseTests {
    @MainActor
    @Test("Releasing the agent chat transcript service off-main does not trap")
    func releasingServiceOffMainThreadDoesNotTrap() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var service: AgentChatTranscriptService? = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            emitEventPayload: { _ in }
        )
        // Keep the only strong reference outside Swift's actor ownership tracking,
        // then release it from a background thread like an async task completion.
        let lastReference = OffMainReleaseBox(Unmanaged.passRetained(try #require(service)))
        service = nil

        await withCheckedContinuation { (released: CheckedContinuation<Void, Never>) in
            Thread {
                lastReference.release()
                released.resume()
            }.start()
        }
        // The production deinit schedules its main-actor cleanup when released off-main.
        await Task.yield()
    }
}

private final class OffMainReleaseBox: @unchecked Sendable {
    private let unmanaged: Unmanaged<AgentChatTranscriptService>

    init(_ unmanaged: Unmanaged<AgentChatTranscriptService>) {
        self.unmanaged = unmanaged
    }

    func release() {
        unmanaged.release()
    }
}
