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
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func replayCompletionUsesBoundaryGeometryBeforeScrollbarPublication() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        surfaceView.authoritativeGeometry = geometry(
            scrollbar(total: 400, offset: 356, len: 44)
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func replayBoundaryIgnoresStalePublishedScrollbarGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, len: 44)
        surfaceView.authoritativeGeometry = geometry(
            scrollbar(total: 400, offset: 356, len: 44)
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
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

        guard case .armed(let expectedStartBoundary, let expectedEndBoundary) =
            panel.hostedView.notificationScrollRestoreState.replay else {
            Issue.record("Replay environment did not arm the in-band boundary")
            return
        }

        #expect(expectedStartBoundary == SessionScrollbackReplayStore.startBoundaryValue(
            forReplayFilePath: replayFilePath
        ))
        #expect(expectedEndBoundary == SessionScrollbackReplayStore.endBoundaryValue(
            forReplayFilePath: replayFilePath
        ))
        #expect(panel.hostedView.notificationScrollRestoreState.pendingPosition == nil)
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
        for _ in 0 ..< 64 {
            postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        }

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

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
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

        let expectedTopRow = Int(retainedTotalRows) - 100 - 44
        #expect(surfaceView.performedBindingActions == ["scroll_to_row:\(expectedTopRow)"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func lateActivationRebasesIntoRetainedReplaySuffix() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 4_000, offset: 3_956, len: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))
        #expect(!hostedView.hasPendingNotificationScrollRestore)
        hostedView.terminalSurfaceDidReceiveExplicitInput()
        postScrollbar(scrollbar(total: 4_100, offset: 4_056, len: 44), to: surfaceView)
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:3856"])
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
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(boundary))

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
        panel.hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "expected-end"),
            request: .waitingForReplay(
                position: TerminalNotificationScrollPosition(row: 100, totalRows: 400),
                attemptsRemaining: 2
            )
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
        panel.hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "expected-end"),
            request: .waitingForReplay(
                position: TerminalNotificationScrollPosition(row: 100, totalRows: 400),
                attemptsRemaining: 2
            )
        )

        _ = panel.performBindingAction("clear_screen")

        #expect(!panel.hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func ordinaryActivationFailsClosedWhenCapturedRowSpaceChanged() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        surfaceView.authoritativeGeometry = NotificationScrollRestoreGeometry(
            scrollbar: scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 100,
                totalRows: 400,
                rowSpaceRevision: 1
            )
        ))

        #expect(surfaceView.performedBindingActions.isEmpty)
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func liveBottomActivationSurvivesRowSpaceRevisionChange() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 356, len: 44)
        surfaceView.authoritativeGeometry = NotificationScrollRestoreGeometry(
            scrollbar: scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 0,
                totalRows: 400,
                rowSpaceRevision: 1
            )
        ))

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:356"])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func internalBindingActionPreservesPendingRestore() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.releaseSurfaceForTesting() }
        panel.hostedView.notificationScrollRestoreState = NotificationScrollRestoreState(
            replay: .replaying(expectedEndBoundary: "expected-end"),
            request: .waitingForReplay(
                position: TerminalNotificationScrollPosition(row: 100, totalRows: 400),
                attemptsRemaining: 2
            )
        )

        _ = panel.performInternalBindingAction("write_screen_file:copy,vt")

        #expect(panel.hostedView.hasPendingNotificationScrollRestore)
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

    private func geometry(
        _ scrollbar: GhosttyScrollbar,
        rowSpaceRevision: UInt64 = 1
    ) -> NotificationScrollRestoreGeometry {
        NotificationScrollRestoreGeometry(
            scrollbar: scrollbar,
            rowSpaceRevision: rowSpaceRevision
        )
    }

    private func postScrollbar(_ scrollbar: GhosttyScrollbar, to surfaceView: GhosttyNSView) {
        surfaceView.scrollbar = scrollbar
        (surfaceView as? NotificationLifecycleRecordingSurfaceView)?.authoritativeGeometry = geometry(scrollbar)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
        )
    }

}

private final class NotificationLifecycleRecordingSurfaceView: GhosttyNSView {
    private(set) var performedBindingActions: [String] = []
    var authoritativeGeometry: NotificationScrollRestoreGeometry?
    var acceptsAtomicScroll = true

    override func performBindingAction(_ action: String) -> Bool {
        performedBindingActions.append(action)
        return true
    }

    override func readAuthoritativeScrollbar(
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        let geometry = authoritativeGeometry ?? scrollbar.map {
            NotificationScrollRestoreGeometry(scrollbar: $0, rowSpaceRevision: 1)
        }
        guard let geometry else { return false }
        result.pointee = cValue(for: geometry)
        return true
    }

    override func scrollToRow(
        _ row: UInt64,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        performedBindingActions.append("scroll_to_row:\(row)")
        let currentGeometry = authoritativeGeometry ?? scrollbar.map {
            NotificationScrollRestoreGeometry(scrollbar: $0, rowSpaceRevision: 1)
        }
        guard acceptsAtomicScroll,
              let currentGeometry,
              currentGeometry.rowSpaceRevision == rowSpaceRevision else {
            return false
        }
        result.pointee = cValue(for: currentGeometry)
        return true
    }

    private func cValue(
        for geometry: NotificationScrollRestoreGeometry
    ) -> ghostty_surface_scrollbar_s {
        ghostty_surface_scrollbar_s(
            total: geometry.scrollbar.total,
            offset: geometry.scrollbar.offset,
            len: geometry.scrollbar.len,
            row_space_revision: geometry.rowSpaceRevision
        )
    }
}
