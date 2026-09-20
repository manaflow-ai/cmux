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
            return Self.releaseOnCurrentThread(&service)
        }

        let releasedOffMainThread = await releaseTask.value
        let didRelease = await MainActor.run { probe.didRelease }
        #expect(releasedOffMainThread)
        #expect(didRelease)
    }

    private static func releaseOnCurrentThread(_ service: inout AgentChatTranscriptService?) -> Bool {
        let isBackgroundThread = !Thread.isMainThread
        service = nil
        return isBackgroundThread
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
