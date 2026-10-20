import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

protocol NotificationScrollRestoreTestSuite {}

extension NotificationScrollRestoreTestSuite {
    @MainActor
    func beginReplay(on hostedView: GhosttySurfaceScrollView, endBoundary: String) {
        let startBoundary = endBoundary + "-start"
        hostedView.armSessionScrollbackReplay(
            expectedStartBoundary: startBoundary,
            expectedEndBoundary: endBoundary
        )
        #expect(hostedView.sessionScrollbackReplayDidReceiveBoundary(startBoundary))
    }

    func scrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(total: total, offset: offset, len: len)
    }

    func geometry(
        _ scrollbar: GhosttyScrollbar,
        rowSpaceRevision: UInt64
    ) -> NotificationScrollRestoreGeometry {
        NotificationScrollRestoreGeometry(
            scrollbar: scrollbar,
            rowSpaceRevision: rowSpaceRevision
        )
    }

    @MainActor
    func postScrollbar(
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

final class NotificationRecoveryRecordingSurfaceView: GhosttyNSView {
    private(set) var performedRows: [Int] = []
    private(set) var attemptedRowSpaceRevisions: [UInt64] = []
    private(set) var acceptedRowSpaceRevisions: [UInt64] = []
    var authoritativeGeometry: NotificationScrollRestoreGeometry?
    var authoritativeGeometryOnNextAtomicScroll: NotificationScrollRestoreGeometry?
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
        if let nextGeometry = authoritativeGeometryOnNextAtomicScroll {
            authoritativeGeometry = nextGeometry
            authoritativeGeometryOnNextAtomicScroll = nil
        }
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
