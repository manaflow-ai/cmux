import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore row space", .serialized)
struct NotificationScrollRestoreRowSpaceTests: NotificationScrollRestoreTestSuite {
    @Test func provisionalRowSpaceRevisionMismatchRetriesAgainstFreshGeometry() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        let staleGeometry = geometry(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )
        surfaceView.authoritativeGeometryOnNextAtomicScroll = geometry(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 3
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: staleGeometry
        ))

        #expect(surfaceView.performedRows == [256])
        #expect(surfaceView.attemptedRowSpaceRevisions == [2])
        #expect(surfaceView.acceptedRowSpaceRevisions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows == [256, 256])
        #expect(surfaceView.attemptedRowSpaceRevisions == [2, 3])
        #expect(surfaceView.acceptedRowSpaceRevisions == [3])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func completedReplayFailsClosedAfterHistoricalRowSpaceChanges() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))

        #expect(surfaceView.performedRows.isEmpty)
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }

    @Test func retainedNotificationRebasesAcrossRespawnRowSpace() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 100,
                totalRows: 400,
                rowSpaceRevision: 1
            )
        ))

        #expect(surfaceView.performedRows == [256])
        #expect(surfaceView.acceptedRowSpaceRevisions == [2])
    }

    @Test func liveNotificationAfterReplayUsesCurrentRowSpaceAndRetainsReplayBaseline() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 400, offset: 356, len: 44))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))
        surfaceView.setAuthoritativeScrollbar(scrollbar(total: 500, offset: 456, len: 44))

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 500, rowSpaceRevision: 1)
        ))
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 10_000)
        ))

        #expect(surfaceView.performedRows == [356, 256])
    }

    @Test func freshNotificationAfterReplayUsesMatchingLiveRowSpace() {
        let boundary = "test-replay-boundary"
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        beginReplay(on: hostedView, endBoundary: boundary)
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(
            boundary,
            authoritativeGeometry: surfaceView.authoritativeGeometry
        ))
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 2
        )

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 100,
                totalRows: 400,
                rowSpaceRevision: 2
            )
        ))

        #expect(surfaceView.performedRows == [256])
        #expect(surfaceView.attemptedRowSpaceRevisions == [2])
        #expect(surfaceView.acceptedRowSpaceRevisions == [2])
    }

    @Test func liveBottomRetriesWhenOutputAppendsDuringAtomicScroll() {
        let surfaceView = NotificationRecoveryRecordingSurfaceView(frame: .zero)
        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 400, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        surfaceView.authoritativeGeometryOnNextAtomicScroll = geometry(
            scrollbar(total: 401, offset: 356, len: 44),
            rowSpaceRevision: 1
        )
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 0,
                totalRows: 400,
                rowSpaceRevision: 1
            )
        ))
        #expect(surfaceView.performedRows == [356])
        #expect(surfaceView.attemptedRowSpaceRevisions == [1])
        #expect(surfaceView.acceptedRowSpaceRevisions == [1])
        #expect(hostedView.hasPendingNotificationScrollRestore)

        surfaceView.setAuthoritativeScrollbar(
            scrollbar(total: 401, offset: 357, len: 44),
            rowSpaceRevision: 1
        )
        postScrollbar(scrollbar(total: 401, offset: 357, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows == [356, 357])
        #expect(surfaceView.attemptedRowSpaceRevisions == [1, 1])
        #expect(surfaceView.acceptedRowSpaceRevisions == [1, 1])
        #expect(!hostedView.hasPendingNotificationScrollRestore)
    }
}
