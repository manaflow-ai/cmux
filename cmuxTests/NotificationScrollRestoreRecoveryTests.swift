import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore recovery", .serialized)
struct NotificationScrollRestoreRecoveryTests: NotificationScrollRestoreTestSuite {
    @Test func missingReplayBoundariesStayPendingUntilExplicitInput() {
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: "missing-start",
            expectedEndBoundary: "missing-end"
        )

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        hostedView.terminalSurfaceDidReceiveExplicitInput()

        #expect(!hostedView.hasPendingNotificationScrollRestore)
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(surfaceView.performedRows == [256])
    }

    @Test func explicitInputCancelsRequestButRetainsReplayAuthority() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        hostedView.terminalSurfaceDidReceiveExplicitInput()
        #expect(!hostedView.hasPendingNotificationScrollRestore)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 500, offset: 456, len: 44))

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))
        #expect(surfaceView.performedRows == [256])
    }

    @Test func activationAfterEndBoundaryUsesAuthoritativeTerminalGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, len: 44)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        #expect(surfaceView.performedRows == [256])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func liveBottomUsesCurrentGeometryAfterQueuedEndBoundary() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let boundaryGeometry = surfaceView.authoritativeGeometry
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 0, totalRows: 400)
        ))
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 500, offset: 456, len: 44))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: boundaryGeometry
        ))

        #expect(surfaceView.performedRows == [456])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test(arguments: [UInt64(4_000), 1_200])
    func boundaryGeometryRebasesTruncatedRestoreIntoRetainedSuffix(retainedTotalRows: UInt64) {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: retainedTotalRows, offset: retainedTotalRows - 44, len: 44)
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(surfaceView.performedRows == [Int(retainedTotalRows) - 100 - 44])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func boundaryGeometryRebasesRestoreWhenReplayGrows() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 410, offset: 366, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(surfaceView.performedRows == [266])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func authoritativeGeometryRebasesNumericallyReachableTruncatedAnchor() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 4_000, offset: 3_956, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 3_000, totalRows: 5_000)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(surfaceView.performedRows == [956])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func missingEndBoundaryDoesNotConsumePendingRestore() {
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: "expected-start",
            expectedEndBoundary: "missing-end"
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary("expected-start"))
        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func portableReplayAnchorUsesCurrentViewportHeight() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 340, len: 60))

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        #expect(surfaceView.performedRows == [240])
    }

    @Test func provisionalReplayAnchorUsesCurrentViewportHeight() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        let boundaryGeometry = geometry(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 340, len: 60),
            rowSpaceRevision: 1
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: boundaryGeometry
        ))

        #expect(surfaceView.performedRows == [240])
    }

    @Test func unavailableAtomicRestoreRetriesOnLaterGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        surfaceView.acceptsAtomicScroll = false
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(surfaceView.performedRows == [256])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        surfaceView.acceptsAtomicScroll = true
        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows == [256, 256])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }
}
