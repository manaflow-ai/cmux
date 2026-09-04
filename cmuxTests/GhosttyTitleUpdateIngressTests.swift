import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty title update ingress")
@MainActor
struct GhosttyTitleUpdateIngressTests {
    @Test func duplicateCallbackTitleIsRejectedBeforeEnqueue() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let terminalLifecycleID = UUID()

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "stable"
        ))
        #expect(!ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "stable"
        ))
        #expect(ingress.submit(
            tabId: UUID(),
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "stable"
        ))
    }

    @Test func spinnerFramesCollapseBeforeAsyncStreamEnqueue() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let terminalLifecycleID = UUID()
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

        for (index, frame) in frames.enumerated() {
            let submitted = ingress.submit(
                tabId: tabId,
                surfaceId: surfaceId,
                sourceSurfaceIdentifier: sourceIdentifier,
                terminalLifecycleID: terminalLifecycleID,
                title: "\(frame) pnpm install"
            )
            #expect(submitted == (index == 0))
        }

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "⠋ pnpm run build"
        ))
    }

    @Test func retiringAttachmentAllowsItsFirstRepeatedTitleAfterReattach() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let terminalLifecycleID = UUID()

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "stable"
        ))
        ingress.retireCurrentAttachment()
        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "stable"
        ))
    }

    @Test func callbackTitleOverrideReplacesTheOscTitle() async throws {
        let center = NotificationCenter()
        let scheduler = TitleScheduleRecorder()
        let ingress = GhosttyTitleUpdateIngress(
            center: center,
            schedule: scheduler.schedule(_:action:)
        )
        let (changes, continuation) = AsyncStream<GhosttyTitleChange>.makeStream()
        let observer = center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: nil
        ) { notification in
            guard let change = GhosttyTitleChange(notification: notification) else {
                return
            }
            continuation.yield(change)
        }
        defer {
            center.removeObserver(observer)
            continuation.finish()
        }
        var iterator = changes.makeAsyncIterator()

        #expect(ingress.submit(
            tabId: UUID(),
            surfaceId: UUID(),
            sourceSurfaceIdentifier: ObjectIdentifier(NSObject()),
            terminalLifecycleID: UUID(),
            title: "⠋",
            titleOverride: "Testare-B"
        ))
        await scheduler.awaitFirstSchedule()
        await scheduler.fire()

        let change = try #require(await iterator.next())
        #expect(change.title == "Testare-B")
    }
}
