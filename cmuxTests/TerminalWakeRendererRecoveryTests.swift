import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalWakeRendererRecoveryTests {
    private final class RecoveryProbe: TerminalWakeRendererRecoverable {
        let isRendererEffectivelyVisible: Bool
        private let recoveredReasons: AsyncStream<String>.Continuation?
        private(set) var reasons: [String] = []

        init(
            isRendererEffectivelyVisible: Bool,
            recoveredReasons: AsyncStream<String>.Continuation? = nil
        ) {
            self.isRendererEffectivelyVisible = isRendererEffectivelyVisible
            self.recoveredReasons = recoveredReasons
        }

        func recoverRendererAfterWake(reason: String) {
            reasons.append(reason)
            recoveredReasons?.yield(reason)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func systemWakeSchedulesVisibleRendererRecovery() async throws {
        let notificationCenter = NotificationCenter()
        let recoveries = AsyncStream<String>.makeStream()
        defer { recoveries.continuation.finish() }
        var recoveryIterator = recoveries.stream.makeAsyncIterator()
        let visible = RecoveryProbe(
            isRendererEffectivelyVisible: true,
            recoveredReasons: recoveries.continuation
        )
        let observers = TerminalWakeRendererRecoveryObserver().install(
            in: notificationCenter,
            surfaces: { [visible] }
        )
        defer {
            for observer in observers {
                notificationCenter.removeObserver(observer)
            }
        }

        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let recoveredReason = try #require(await recoveryIterator.next())
        #expect(recoveredReason == "workspace.didWake")
    }

    @Test(.timeLimit(.minutes(1)))
    func observerCoalescesWakeSignalsAndSkipsHiddenSurfaces() async throws {
        let notificationCenter = NotificationCenter()
        let recoveries = AsyncStream<String>.makeStream()
        defer { recoveries.continuation.finish() }
        var recoveryIterator = recoveries.stream.makeAsyncIterator()
        let visible = RecoveryProbe(
            isRendererEffectivelyVisible: true,
            recoveredReasons: recoveries.continuation
        )
        let hidden = RecoveryProbe(isRendererEffectivelyVisible: false)
        let scheduler = TerminalWakeRendererRecoveryScheduler()
        let observers = TerminalWakeRendererRecoveryObserver(
            scheduler: scheduler
        ).install(
            in: notificationCenter,
            surfaces: { [visible, hidden] }
        )
        defer {
            for observer in observers {
                notificationCenter.removeObserver(observer)
            }
        }

        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        let recoveredReason = try #require(await recoveryIterator.next())
        #expect(recoveredReason == "workspace.screensDidWake")
        #expect(visible.reasons == ["workspace.screensDidWake"])
        #expect(hidden.reasons.isEmpty)
    }
}
