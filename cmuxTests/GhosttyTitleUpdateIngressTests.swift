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

    /// Frames are forwarded, not collapsed, so the tab label keeps animating.
    /// The saving comes from what they carry, not from dropping them.
    /// https://github.com/manaflow-ai/cmux/issues/10348
    @Test func spinnerFramesAreForwardedSoTheTabLabelKeepsAnimating() {
        let ingress = GhosttyTitleUpdateIngress()
        let tabId = UUID()
        let surfaceId = UUID()
        let sourceIdentifier = ObjectIdentifier(NSObject())
        let terminalLifecycleID = UUID()
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

        for frame in frames {
            #expect(ingress.submit(
                tabId: tabId,
                surfaceId: surfaceId,
                sourceSurfaceIdentifier: sourceIdentifier,
                terminalLifecycleID: terminalLifecycleID,
                title: "\(frame) pnpm install"
            ))
        }

        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "⠋ pnpm run build"
        ))
    }

    /// A repeated identical frame still dedups; only genuinely new frames pass.
    @Test func repeatedIdenticalFrameIsStillRejected() {
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
            title: "⠋ pnpm install"
        ))
        #expect(!ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "⠋ pnpm install"
        ))
    }

    /// The whole point: consecutive frames differ in `title` so the tab redraws,
    /// and agree on `stableTitle` so every expensive consumer can skip them.
    @Test func consecutiveFramesShareOneStableTitle() {
        let frames = ["⠋", "⠙", "⠹"].map { frame in
            GhosttyTitleChange(
                tabId: UUID(),
                surfaceId: UUID(),
                title: "\(frame) pnpm install",
                stableTitle: "pnpm install"
            )
        }

        #expect(Set(frames.map(\.title)).count == 3)
        #expect(Set(frames.map(\.stableTitle)) == ["pnpm install"])
        #expect(frames.allSatisfy(\.isSpinnerFrameOnly))
    }

    @Test func aRealLabelChangeIsNotMarkedSpinnerOnly() {
        let change = GhosttyTitleChange(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "pnpm run build",
            stableTitle: "pnpm run build"
        )

        #expect(!change.isSpinnerFrameOnly)
    }

    /// A payload from a legacy in-process post carries no stable title. Treating
    /// it as a real change is the safe direction: stale chrome beats churn.
    @Test func missingStableTitleFallsBackToTheRawTitle() {
        let change = GhosttyTitleChange(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "⠋ pnpm install"
        )

        #expect(change.stableTitle == "⠋ pnpm install")
        #expect(!change.isSpinnerFrameOnly)
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
