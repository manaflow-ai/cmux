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
    @Test func replayCompletionDropsAnUnreachableHistoricalRestore() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.sessionScrollbackReplayDidBegin()

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        hostedView.sessionScrollbackReplayDidComplete()
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)

        postScrollbar(scrollbar(total: 400, offset: 356, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions.isEmpty)
    }

    @Test func replayCompletionUsesTheFirstPostReplayGeometryPacket() {
        let surfaceView = NotificationLifecycleRecordingSurfaceView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 0, offset: 0, len: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.sessionScrollbackReplayDidBegin()

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 100, totalRows: 400)
        ))
        postScrollbar(scrollbar(total: 100, offset: 56, len: 44), to: surfaceView)
        hostedView.sessionScrollbackReplayDidComplete()

        postScrollbar(scrollbar(total: 400, offset: 0, len: 44), to: surfaceView)

        #expect(surfaceView.performedBindingActions == ["scroll_to_row:256"])
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
}

private final class NotificationLifecycleRecordingSurfaceView: GhosttyNSView {
    private(set) var performedBindingActions: [String] = []

    override func performBindingAction(_ action: String) -> Bool {
        performedBindingActions.append(action)
        return true
    }
}
