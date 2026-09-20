import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct AgentChatTranscriptServiceLifetimeTests {
    @Test("transcript service tears down when its final owner releases off the main actor")
    func finalReleaseFromDetachedTask() async {
        let probe = await MainActor.run { AgentChatTranscriptServiceLifetimeProbe() }
        let releaseTask = Task.detached {
            var service: AgentChatTranscriptService? = await MainActor.run {
                AgentChatTranscriptService(
                    registry: AgentChatSessionRegistry(),
                    hasEventSubscribers: { false },
                    emitEventPayload: { _ in }
                )
            }

            await probe.capture(service)
            #expect(!Thread.isMainThread)
            service = nil
        }

        await releaseTask.value
        let didRelease = await MainActor.run { probe.didRelease }
        #expect(didRelease)
    }
}

@MainActor
private final class AgentChatTranscriptServiceLifetimeProbe {
    private weak var service: AgentChatTranscriptService?

    var didRelease: Bool {
        service == nil
    }

    func capture(_ service: AgentChatTranscriptService?) {
        self.service = service
    }
}
