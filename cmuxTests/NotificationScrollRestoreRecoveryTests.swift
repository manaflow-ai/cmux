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
struct NotificationScrollRestoreRecoveryTests {
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

    @Test func rowSpaceRevisionMismatchRetriesAgainstFreshGeometry() {
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
        #expect(surfaceView.attemptedRowSpaceRevisions == [1])
        #expect(surfaceView.acceptedRowSpaceRevisions.isEmpty)
        #expect(hostedView.hasPendingNotificationScrollRestore)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedRows == [256, 256])
        #expect(surfaceView.attemptedRowSpaceRevisions == [1, 2])
        #expect(surfaceView.acceptedRowSpaceRevisions == [2])
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

    private func beginReplay(on hostedView: GhosttySurfaceScrollView, endBoundary: String) {
        let startBoundary = endBoundary + "-start"
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: startBoundary,
            expectedEndBoundary: endBoundary
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(startBoundary))
    }

    private func scrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(total: total, offset: offset, len: len)
    }

    private func geometry(
        _ scrollbar: GhosttyScrollbar,
        rowSpaceRevision: UInt64
    ) -> NotificationScrollRestoreGeometry {
        NotificationScrollRestoreGeometry(
            scrollbar: scrollbar,
            rowSpaceRevision: rowSpaceRevision
        )
    }

    private func postScrollbar(
        _ scrollbar: GhosttyScrollbar,
        to surfaceView: NotificationRecoveryRecordingSurfaceView
    ) {
        surfaceView.scrollbar = scrollbar
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
        )
    }
}

private final class NotificationRecoveryRecordingSurfaceView: GhosttyNSView {
    private(set) var performedRows: [Int] = []
    private(set) var attemptedRowSpaceRevisions: [UInt64] = []
    private(set) var acceptedRowSpaceRevisions: [UInt64] = []
    var authoritativeGeometry: NotificationScrollRestoreGeometry?
    var acceptsAtomicScroll = true

    func setAuthoritativeScrollbar(
        _ scrollbar: GhosttyScrollbar,
        rowSpaceRevision: UInt64 = 1
    ) {
        authoritativeGeometry = NotificationScrollRestoreGeometry(
            scrollbar: scrollbar,
            rowSpaceRevision: rowSpaceRevision
        )
    }

    override func readAuthoritativeScrollbar(
        _ result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        guard let authoritativeGeometry else { return false }
        result.pointee = cValue(for: authoritativeGeometry)
        return true
    }

    override func scrollToRow(
        _ row: UInt64,
        ifRowSpaceRevisionMatches rowSpaceRevision: UInt64,
        result: UnsafeMutablePointer<ghostty_surface_scrollbar_s>
    ) -> Bool {
        performedRows.append(Int(clamping: row))
        attemptedRowSpaceRevisions.append(rowSpaceRevision)
        guard acceptsAtomicScroll,
              let authoritativeGeometry,
              authoritativeGeometry.rowSpaceRevision == rowSpaceRevision else {
            return false
        }
        acceptedRowSpaceRevisions.append(rowSpaceRevision)
        result.pointee = cValue(for: authoritativeGeometry)
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
