import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore lifecycle", .serialized)
struct NotificationScrollRestoreLifecycleTests {
    @Test func replayCompletionKeepsHistoricalRestoreUntilRowsBecomeAddressable() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func replayCompletionUsesTheFirstRenderedFrameAfterGeometryUpdate() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        postScrollbar(scrollbar(total: 400, offset: 0, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
    }

    @Test func renderedFrameWaitsForItsFollowingScrollbarPublication() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        postRenderedFrameOnly(to: surfaceView)
        #expect(surfaceView.performedBindingActions.isEmpty)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func replayCompletionUsesAlreadyPublishedFinalGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func promptIdleDoesNotCompleteTheInBandReplayLifecycle() throws {
        let boundary = "test-replay-boundary"
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        let hostedView = panel.hostedView
        hostedView.surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.hasPendingNotificationScrollRestore)

        panel.updateShellActivityState(.promptIdle)
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: hostedView.surfaceView)

        #expect(hostedView.hasPendingNotificationScrollRestore)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: hostedView.surfaceView)

        #expect(hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func mismatchedInBandBoundaryDoesNotCompleteReplay() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: "expected")

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(!hostedView.sessionScrollbackReplayDidReceiveBoundary("other"))
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(hostedView.hasPendingNotificationScrollRestore)
        #expect(surfaceView.performedBindingActions.isEmpty)
    }

    @Test func replayEnvironmentArmsBoundaryBeforeTheSurfaceIsMounted() throws {
        let replayFilePath = "/tmp/cmux-replay-boundary-test"
        let workspace = Workspace()
        let paneId = try #require(
            workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        )
        let panel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            startupEnvironment: [SessionScrollbackReplayStore.environmentKey: replayFilePath]
        ))
        defer { panel.surface.releaseSurfaceForTesting() }

        guard case .armed(let expectedStartBoundary, let expectedEndBoundary, let pendingPosition, _) =
            panel.hostedView.notificationScrollRestoreState else {
            Issue.record("Replay environment did not arm the in-band boundary")
            return
        }

        #expect(expectedStartBoundary == SessionScrollbackReplayStore.startBoundaryValue(
            forReplayFilePath: replayFilePath
        ))
        #expect(expectedEndBoundary == SessionScrollbackReplayStore.endBoundaryValue(
            forReplayFilePath: replayFilePath
        ))
        #expect(pendingPosition == nil)
    }

    @Test func armedReplayWaitsForStartBoundaryBeforeRestoring() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let startBoundary = "expected-start"
        let endBoundary = "expected-end"
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: startBoundary,
            expectedEndBoundary: endBoundary
        )

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(startBoundary))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(endBoundary))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func postReplayRestoreRemainsPendingAcrossPartialGeometryUpdates() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        for _ in 0 ..< 64 {
            postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        }

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test(arguments: [UInt64(4_000), 1_200])
    func truncatedReplayWaitsForRenderedFrameBeforeRebasingIntoRetainedSuffix(
        retainedTotalRows: UInt64
    ) {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        let partialTotalRows = retainedTotalRows / 2
        postScrollbar(
            scrollbar(total: partialTotalRows, offset: partialTotalRows - 44, len: 44),
            to: surfaceView
        )

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(
            scrollbar(total: retainedTotalRows, offset: retainedTotalRows - 44, len: 44),
            to: surfaceView
        )

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        let expectedTopRow = Int(retainedTotalRows) - 100 - 44
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:\(expectedTopRow)"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func legacyRestoreWaitsForPostReplayGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 12, totalRows: nil)
        ))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postRenderedFrame(to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:344"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func unreachableActiveSurfaceGeometryDoesNotRemainPending() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func anchorlessActivationClearsPendingRestoreWhilePanelIsHibernated() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.hostedView.notificationScrollRestoreState = .replaying(
            expectedBoundary: "expected-end",
            pendingPosition: TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        )
        panel.enterAgentHibernation(
            agent: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "hibernated-scroll-test",
                workingDirectory: nil,
                launchCommand: nil
            ),
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        #expect(panel.isAgentHibernated)
        #expect(!panel.restoreNotificationScrollPosition(nil))
        #expect(!panel.hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func panelBindingActionCancelsPendingRestoreForAutomationEntrypoints() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.hostedView.notificationScrollRestoreState = .replaying(
            expectedBoundary: "expected-end",
            pendingPosition: TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        )

        _ = panel.performBindingAction("clear_screen")

        #expect(!panel.hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func internalBindingActionPreservesPendingRestore() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.hostedView.notificationScrollRestoreState = .replaying(
            expectedBoundary: "expected-end",
            pendingPosition: TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        )

        _ = panel.performInternalBindingAction("write_screen_file:copy,vt")

        #expect(panel.hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func renderedFrameDemandIsScopedToTheRestoringSurface() {
        let restoringSurface = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        let unrelatedSurface = NotificationLifecycleRecordingSurfaceView(frame: .zero)

        let release = restoringSurface.retainTargetedRenderedFrameNotifications()

        #expect(restoringSurface.targetedRenderedFrameNotificationDemand.isActive)
        #expect(!unrelatedSurface.targetedRenderedFrameNotificationDemand.isActive)
        release()
        #expect(!restoringSurface.targetedRenderedFrameNotificationDemand.isActive)
    }

    @Test func missingRenderedFrameDeadlineReleasesDemandWithoutDiscardingRestore() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
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
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
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
        postRenderedFrameOnly(to: surfaceView)
        if let scrollbar = surfaceView.scrollbar {
            postScrollbar(scrollbar, to: surfaceView)
        }
    }

    private func postRenderedFrameOnly(to surfaceView: GhosttyNSView) {
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: surfaceView,
            userInfo: ["ghostty.renderedFrameGeneration": UInt64.max]
        )
    }
}

private final class NotificationLifecycleRecordingSurfaceView: GhosttyNSView {
    private(set) var performedBindingActions: [String] = []

    override func performBindingAction(_ action: String) -> Bool {
        performedBindingActions.append(action)
        return true
    }
}
