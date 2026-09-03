import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Collects the title changes posted to a test-owned notification center. The
/// ingress posts from its consumer task, so the reads are locked.
final class GhosttyTitleChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GhosttyTitleChange] = []

    var values: [GhosttyTitleChange] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ change: GhosttyTitleChange) {
        lock.lock()
        recorded.append(change)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }
}

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
    ///
    /// The assertions read the changes that actually reach `.ghosttyDidSetTitle`
    /// rather than `submit`'s return value, so a later stage that dropped a
    /// frame's `stableTitle` or its spinner-only marking would fail here. The
    /// ingress stream buffers the newest update, so the number of posted changes
    /// is not fixed; what every posted frame carries is.
    /// https://github.com/manaflow-ai/cmux/issues/10348
    @Test func spinnerFramesAreForwardedSoTheTabLabelKeepsAnimating() async {
        let center = NotificationCenter()
        let scheduler = TitleScheduleRecorder()
        let observed = GhosttyTitleChangeRecorder()
        let token = center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: nil
        ) { notification in
            if let change = GhosttyTitleChange(notification: notification) {
                observed.append(change)
            }
        }
        defer { center.removeObserver(token) }

        let ingress = GhosttyTitleUpdateIngress(
            center: center,
            schedule: { interval, action in scheduler.schedule(interval, action: action) }
        )
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
        await scheduler.awaitFirstSchedule()
        await scheduler.fire()

        let spinnerChanges = observed.values
        let everySpinnerChangeSharesTheStableTitle = spinnerChanges
            .allSatisfy { $0.stableTitle == "pnpm install" }
        let everySpinnerChangeIsMarkedSpinnerOnly = spinnerChanges.allSatisfy(\.isSpinnerFrameOnly)
        let everySpinnerChangeKeepsItsFrame = spinnerChanges
            .allSatisfy { $0.title.hasSuffix(" pnpm install") }
        #expect(!spinnerChanges.isEmpty)
        #expect(everySpinnerChangeSharesTheStableTitle)
        #expect(everySpinnerChangeIsMarkedSpinnerOnly)
        #expect(everySpinnerChangeKeepsItsFrame)

        observed.reset()
        #expect(ingress.submit(
            tabId: tabId,
            surfaceId: surfaceId,
            sourceSurfaceIdentifier: sourceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            title: "pnpm run build"
        ))
        await scheduler.awaitFirstSchedule()
        await scheduler.fire()

        // A frame-free title: `isSpinnerFrameOnly` is `title != stableTitle`, so a
        // real label change only reads as one when the raw title has no frame in
        // it. That is the case a consumer must not skip.
        let labelChanges = observed.values
        let everyLabelChangeCarriesTheNewTitle = labelChanges
            .allSatisfy { $0.stableTitle == "pnpm run build" }
        let noLabelChangeIsMarkedSpinnerOnly = labelChanges.allSatisfy { !$0.isSpinnerFrameOnly }
        #expect(!labelChanges.isEmpty)
        #expect(everyLabelChangeCarriesTheNewTitle)
        #expect(noLabelChangeIsMarkedSpinnerOnly)
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

        let everyFrameIsMarkedSpinnerOnly = frames.allSatisfy(\.isSpinnerFrameOnly)
        #expect(Set(frames.map(\.title)).count == 3)
        #expect(Set(frames.map(\.stableTitle)) == ["pnpm install"])
        #expect(everyFrameIsMarkedSpinnerOnly)
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
    /// it as a real change is the safe direction: it permits a refresh, and
    /// churn beats stale chrome.
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
