import Foundation
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension NotificationScrollRestoreTests {
    @Test func rowSpaceRevisionInvalidatesPreReplayNotification() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-row-space-revision")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: scrollbar(total: 200, offset: 156, visible: 44),
            rowSpaceRevision: 7
        ))

        hostedView.updateScrollbackRowSpaceRevision(8)
        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .idle)
    }

    @Test func rowSpaceRevisionInvalidatesSameGenerationNotification() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "same-generation-row-space-revision")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: scrollbar(total: 200, offset: 156, visible: 44),
            rowSpaceRevision: 7
        ))

        hostedView.updateScrollbackRowSpaceRevision(8)
        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 40,
                totalRows: 200,
                replayGeneration: marker.reportedDirectory,
                rowSpaceRevision: 7
            )
        ))
        #expect(surfaceView.bindingActions.isEmpty)
    }

    @Test func revisionAwarePositionFailsClosedAcrossReplayGenerations() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "cross-generation-row-space-revision")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: surfaceView.scrollbar,
            rowSpaceRevision: 7
        ))

        #expect(!hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 40, totalRows: 200, rowSpaceRevision: 7)
        ))
        #expect(surfaceView.bindingActions.isEmpty)
    }

    @Test func rowSpaceRevisionDoesNotInvalidateBottomAnchor() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        hostedView.updateScrollbackRowSpaceRevision(8)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 0,
                totalRows: 200,
                replayGeneration: "older-generation",
                rowSpaceRevision: 7
            )
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_bottom"])
    }

    @Test func rowSpaceRevisionTracksLatestSurfaceIncarnation() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 116, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        hostedView.updateScrollbackRowSpaceRevision(8)
        hostedView.updateScrollbackRowSpaceRevision(1)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(
                row: 40,
                totalRows: 200,
                rowSpaceRevision: 1
            )
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:116"])
    }

    @Test func postReplayNotificationUsesItsLiveGeneration() throws {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "post-replay-notification")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: scrollbar(total: 200, offset: 156, visible: 44)
        ))

        postScrollbar(total: 220, offset: 126, visible: 44, to: surfaceView)
        let postReplayPosition = try #require(hostedView.notificationScrollPosition)
        #expect(postReplayPosition.row == 50)
        #expect(postReplayPosition.replayGeneration == marker.reportedDirectory)
        #expect(hostedView.restoreNotificationScrollPosition(postReplayPosition))
        #expect(surfaceView.bindingActions == ["scroll_to_row:126"])
    }

    @Test func replayCompletionBeforeArtifactAdoptionIsPreserved() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-complete-before-adoption")
        #expect(completeReplay(hostedView, marker: marker, scrollbar: surfaceView.scrollbar))
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(hostedView.notificationScrollRestorePhase == .idle)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
    }

    @Test func completionUsesAuthoritativeSnapshotInsteadOfCachedScrollbar() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let authoritativeScrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = makeHostedView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-authoritative-snapshot")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(completeReplay(hostedView, marker: marker, scrollbar: authoritativeScrollbar))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
        #expect(surfaceView.scrollbar?.total == 200)
    }

    @Test func authoritativeRestoreGeometryMarksViewportAwayFromBottom() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        surfaceView.enqueueScrollbarUpdate(scrollbar(total: 120, offset: 76, visible: 44))
        let hostedView = makeHostedView(surfaceView: surfaceView)

        #expect(hostedView.performNotificationScrollRestore(
            .absoluteRow(218),
            scrollbar: scrollbar(total: 400, offset: 218, visible: 44)
        ))
        #expect(hostedView.userScrolledAwayFromBottom)
        #expect(surfaceView.scrollbar?.total == 400)
        #expect(surfaceView.scrollbar?.offset == 218)
        #expect(!surfaceView.flushPendingScrollbarIfAvailable())
        #expect(surfaceView.bindingActions == ["scroll_to_row:218"])
    }

    @Test func restoreWaitsForUsableAppKitViewport() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 218, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions.isEmpty)

        surfaceView.cellSize = CGSize(width: 8, height: 16)
        hostedView.frame = CGRect(x: 0, y: 0, width: 800, height: 640)
        hostedView.layoutSubtreeIfNeeded()
        #expect(surfaceView.bindingActions == ["scroll_to_row:218"])
    }
}
