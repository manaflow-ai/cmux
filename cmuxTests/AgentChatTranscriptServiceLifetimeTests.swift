import CMUXAgentLaunch
import CmuxAgentChat
@testable import CmuxMobileHost
import CmuxTerminal
import CmuxTerminalCore
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
    func finalReleaseFromDetachedTask() async throws {
        let events = AsyncStream<AgentChatTranscriptNotificationRecorder.Event>.makeStream()
        defer { events.continuation.finish() }
        let notificationCenter = AgentChatTranscriptNotificationRecorder(events: events.continuation)
        let frameDemand = RenderDemandCounter()
        let tickDemand = RenderDemandCounter()
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = await MainActor.run { AgentChatTranscriptServiceLifetimeProbe() }
        let releaseTask = Task.detached {
            var service: AgentChatTranscriptService? = await MainActor.run {
                let service = AgentChatTranscriptService(
                    registry: AgentChatSessionRegistry(
                        hookStore: AgentChatHookSessionStore(homeDirectory: home)
                    ),
                    resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
                    hasEventSubscribers: { true },
                    emitEventPayload: { _ in },
                    notificationCenter: notificationCenter,
                    renderedFrameNotificationDemand: frameDemand,
                    tickNotificationDemand: tickDemand
                )
                let sessionID = UUID().uuidString
                let surfaceID = UUID().uuidString
                let now = Date()
                for eventName in [WorkstreamEvent.HookEventName.sessionStart, .userPromptSubmit] {
                    service.noteHookEvent(WorkstreamEvent(
                        sessionId: sessionID,
                        hookEventName: eventName,
                        source: "codex",
                        surfaceId: surfaceID,
                        receivedAt: now
                    ))
                }
                probe.capture(service, frameDemand: frameDemand, tickDemand: tickDemand)
                return service
            }

            let serviceForShutdown = service
            await MainActor.run { serviceForShutdown?.shutdown() }
            return Self.releaseOnCurrentThread(&service)
        }

        let releasedOffMainThread = await releaseTask.value
        #expect(releasedOffMainThread)
        var iterator = events.stream.makeAsyncIterator()
        var addedObserverIDs: Set<ObjectIdentifier> = []
        var addedNames: Set<Notification.Name> = []
        for _ in 0..<3 {
            guard case let .added(name, observerID) = try #require(await iterator.next()) else {
                Issue.record("Expected a registered streaming observer before teardown")
                return
            }
            addedObserverIDs.insert(observerID)
            addedNames.insert(try #require(name))
        }
        #expect(addedNames == [.mobileHostEventSubscriptionsDidChange, .ghosttyDidRenderFrame, .ghosttyDidTick])
        var removedObserverIDs: Set<ObjectIdentifier> = []
        for _ in 0..<3 {
            guard case let .removed(observerID, onMainThread) = try #require(await iterator.next()) else {
                Issue.record("Expected streaming observers to be removed during teardown")
                return
            }
            #expect(onMainThread)
            removedObserverIDs.insert(observerID)
        }
        #expect(removedObserverIDs == addedObserverIDs)

        // stop() and stopAll() are synchronous in the same MainActor task;
        // entering that actor after observer removal also observes both stops.
        try await MainActor.run {
            #expect(probe.didRelease)
            #expect(probe.hadActiveUnsettledTurn)
            #expect(probe.frameDemandWasActive)
            #expect(probe.tickDemandWasActive)
            #expect(!frameDemand.isActive)
            #expect(!tickDemand.isActive)
        }
    }

    @MainActor
    @Test("shutdown rejects late hooks, resume requests, and registry notifications")
    func shutdownRejectsLateIngress() throws {
        let home = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = AgentChatSessionRegistry(hookStore: AgentChatHookSessionStore(homeDirectory: home))
        let notificationCenter = NotificationCenter()
        let frameDemand = RenderDemandCounter()
        let tickDemand = RenderDemandCounter()
        var emittedPayloadCount = 0
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { _ in emittedPayloadCount += 1 },
            notificationCenter: notificationCenter,
            renderedFrameNotificationDemand: frameDemand,
            tickNotificationDemand: tickDemand
        )
        defer { service.shutdown() }
        let sessionID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let now = Date()
        for eventName in [WorkstreamEvent.HookEventName.sessionStart, .userPromptSubmit] {
            service.noteHookEvent(WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: eventName,
                source: "codex",
                surfaceId: surfaceID,
                receivedAt: now
            ))
        }
        #expect(frameDemand.isActive)
        #expect(tickDemand.isActive)

        service.shutdown()
        service.shutdown()
        let payloadCountAtShutdown = emittedPayloadCount
        let recordAtShutdown = try #require(service.sessionRecord(sessionID: sessionID))
        let lateSessionID = UUID().uuidString
        service.noteHookEvent(WorkstreamEvent(
            sessionId: lateSessionID,
            hookEventName: .userPromptSubmit,
            source: "codex",
            surfaceId: surfaceID,
            receivedAt: now
        ))
        service.noteResumeInitiated(
            sessionID: sessionID,
            source: "codex",
            surfaceID: UUID().uuidString,
            workspaceID: UUID().uuidString,
            workingDirectory: home.path
        )
        service.start()
        #expect(service.sessionRecord(sessionID: lateSessionID) == nil)
        let recordAfterIngress = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(recordAfterIngress.version == recordAtShutdown.version)
        #expect(recordAfterIngress.surfaceID == surfaceID)

        registry.update(sessionID: sessionID) { $0.title = "Late registry update" }
        notificationCenter.post(name: .mobileHostEventSubscriptionsDidChange, object: nil)
        notificationCenter.post(name: .ghosttyDidTick, object: nil)
        #expect(emittedPayloadCount == payloadCountAtShutdown)
        #expect(!frameDemand.isActive)
        #expect(!tickDemand.isActive)
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
    private(set) var hadActiveUnsettledTurn = false
    private(set) var frameDemandWasActive = false
    private(set) var tickDemandWasActive = false

    var didRelease: Bool {
        service == nil
    }

    func capture(
        _ service: AgentChatTranscriptService?,
        frameDemand: RenderDemandCounter,
        tickDemand: RenderDemandCounter
    ) {
        self.service = service
        hadActiveUnsettledTurn = frameDemand.isActive && tickDemand.isActive
        frameDemandWasActive = frameDemand.isActive
        tickDemandWasActive = tickDemand.isActive
    }
}
