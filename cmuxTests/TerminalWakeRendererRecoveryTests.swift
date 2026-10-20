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

    @Test
    func displayWakeNotificationReachesTheRecoveryCallback() {
        let notificationCenter = NotificationCenter()
        var displayWakeCount = 0
        let observers = RemoteSessionPowerObserver().install(
            in: notificationCenter,
            onWillSleep: {},
            onDidWake: {},
            onScreensDidWake: { displayWakeCount += 1 }
        )
        defer {
            for observer in observers {
                notificationCenter.removeObserver(observer)
            }
        }

        notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        #expect(displayWakeCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func recoveryCoalescesWakeSignalsAndSkipsHiddenSurfaces() async throws {
        let recoveries = AsyncStream<String>.makeStream()
        defer { recoveries.continuation.finish() }
        var recoveryIterator = recoveries.stream.makeAsyncIterator()
        let visible = RecoveryProbe(
            isRendererEffectivelyVisible: true,
            recoveredReasons: recoveries.continuation
        )
        let hidden = RecoveryProbe(isRendererEffectivelyVisible: false)
        let scheduler = TerminalWakeRendererRecoveryScheduler()

        scheduler.schedule(
            surfaces: { [visible, hidden] },
            reason: "workspace.didWake"
        )
        scheduler.schedule(
            surfaces: { [visible, hidden] },
            reason: "workspace.screensDidWake"
        )

        let recoveredReason = try #require(await recoveryIterator.next())
        #expect(recoveredReason == "workspace.screensDidWake")
        #expect(visible.reasons == ["workspace.screensDidWake"])
        #expect(hidden.reasons.isEmpty)
    }

    @Test
    func appDelegateRoutesDisplayWakeIntoRendererRecovery() {
#if DEBUG
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        appDelegate.debugInstallLifecycleSnapshotObserversForTesting()
        let initialCount =
            appDelegate.debugTerminalWakeRendererRecoveryScheduleCount

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        #expect(
            appDelegate.debugTerminalWakeRendererRecoveryScheduleCount
                == initialCount + 1
        )
#endif
    }
}
