import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore recovery", .serialized)
struct NotificationScrollRestoreRecoveryTests {
    @Test func missingReplayBoundariesFallBackToLiveGeometryAtDeadline() {
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: "missing-start",
            expectedEndBoundary: "missing-end"
        )

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.notificationScrollRestoreFrameDeadlineTimer != nil)
        hostedView.expireNotificationScrollRestoreFrameDeadline()

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func activationAfterEndBoundaryWaitsForAuthoritativeGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)
        #expect(surfaceView.performedBindingActions.isEmpty)

        postRenderedFrame(to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func frameDeadlineRebasesTruncatedRestoreFromLatestGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 1_200, offset: 1_156, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        hostedView.expireNotificationScrollRestoreFrameDeadline()

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)
        postScrollbar(scrollbar(total: 1_200, offset: 1_156, len: 44), to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:1056"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func authoritativeGeometryRebasesNumericallyReachableTruncatedAnchor() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 4_000, offset: 3_956, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 3_000, totalRows: 5_000)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:956"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func missingEndBoundaryFallsBackAtReplayDeadline() {
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: "expected-start",
            expectedEndBoundary: "missing-end"
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary("expected-start"))
        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        hostedView.expireNotificationScrollRestoreFrameDeadline()

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func renderedFrameDemandIsScopedToTheRestoringSurface() {
        let restoringSurface = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        let unrelatedSurface = NotificationRecoveryRecordingSurfaceView(frame: .zero)

        let release = restoringSurface.retainTargetedRenderedFrameNotifications()

        #expect(restoringSurface.targetedRenderedFrameNotificationDemand.isActive)
        #expect(!unrelatedSurface.targetedRenderedFrameNotificationDemand.isActive)
        release()
        #expect(!restoringSurface.targetedRenderedFrameNotificationDemand.isActive)
    }

    @Test func missingRenderedFrameDeadlineReleasesDemandWithoutDiscardingRestore() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        #expect(hostedView.notificationScrollRestoreRenderedFrameObserver != nil)
        #expect(hostedView.releaseNotificationScrollRestoreFrameDemand != nil)
        #expect(hostedView.notificationScrollRestoreFrameDeadlineTimer != nil)

        hostedView.expireNotificationScrollRestoreFrameDeadline()

        #expect(hostedView.hasPendingNotificationScrollRestore)
        #expect(hostedView.notificationScrollRestoreRenderedFrameObserver == nil)
        #expect(hostedView.releaseNotificationScrollRestoreFrameDemand == nil)
        #expect(hostedView.notificationScrollRestoreFrameDeadlineTimer == nil)
        #expect(hostedView.notificationScrollRestoreBoundaryFrameGeneration == nil)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func missingTerminalBindingAtReplayBoundaryKeepsRestorePending() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(hostedView.hasPendingNotificationScrollRestore)
        #expect(surfaceView.terminalSurface == nil)
        #expect(hostedView.notificationScrollRestoreRenderedFrameObserver != nil)
        #expect(hostedView.releaseNotificationScrollRestoreFrameDemand != nil)

        hostedView.expireNotificationScrollRestoreFrameDeadline()

        #expect(hostedView.hasPendingNotificationScrollRestore)
        #expect(hostedView.notificationScrollRestoreRenderedFrameObserver == nil)
        #expect(hostedView.releaseNotificationScrollRestoreFrameDemand == nil)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    private func beginReplay(on hostedView: GhosttySurfaceScrollView, endBoundary: String) {
        let startBoundary = endBoundary + "-start"
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: startBoundary,
            expectedEndBoundary: endBoundary
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(startBoundary))
    }

    private func scrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: total, offset: offset, len: len))
    }

    private func postScrollbar(_ scrollbar: GhosttyScrollbar, to surfaceView: GhosttyNSView) {
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
        )
    }

    private func postRenderedFrame(to surfaceView: GhosttyNSView) {
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: surfaceView,
            userInfo: ["ghostty.renderedFrameGeneration": UInt64.max]
        )
        if let scrollbar = surfaceView.scrollbar {
            postScrollbar(scrollbar, to: surfaceView)
        }
    }
}

private final class NotificationRecoveryRecordingSurfaceView: GhosttyNSView {
    private(set) var performedBindingActions: [String] = []

    override func performBindingAction(_ action: String) -> Bool {
        performedBindingActions.append(action)
        return true
    }
}
