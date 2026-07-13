import AppKit
import Foundation
import CmuxTerminal
import CmuxTerminalCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Notification scroll restore", .serialized)
struct NotificationScrollRestoreTests {
    final class ActionProbeView: GhosttyNSView {
        private(set) var bindingActions: [String] = []

        override func performBindingAction(_ action: String, recordsExplicitInput: Bool) -> Bool {
            bindingActions.append(action)
            return true
        }
    }

    @Test func targetUsesGhosttyAbsoluteRow() {
        let hostedView = makeHostedView(total: 400, offset: 218, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ) == .absoluteRow(218))
    }

    @Test func targetFollowsLiveBottomWhenCapturedAtBottom() {
        let hostedView = makeHostedView(total: 500, offset: 456, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 0, totalRows: 400)
        ) == .bottom)
    }

    @Test func targetRequiresVisibleRows() {
        let hostedView = makeHostedView(total: 400, offset: 218, visible: 0)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ) == nil)
    }

    @Test func targetRebasesWhenHistoryRetainsOnlyCapturedSuffix() {
        let hostedView = makeHostedView(total: 200, offset: 156, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ) == .absoluteRow(18))
    }

    @Test func targetClampsToTopWhenCapturedViewportWasDiscarded() {
        let hostedView = makeHostedView(total: 200, offset: 156, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 300, totalRows: 400)
        ) == .absoluteRow(0))
    }

    @Test func targetSupportsLegacyRowOnlyPosition() {
        let hostedView = makeHostedView(total: 400, offset: 218, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138)
        ) == .absoluteRow(218))
    }

    @Test func restoreRebasesWhenHistoryRetainsOnlyCapturedSuffix() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
    }

    @Test func restoreWaitsForUsableViewport() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 218, visible: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        postScrollbar(total: 400, offset: 218, visible: 44, to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:218"])
    }

    @Test func notificationWithoutPositionSupersedesPendingRestore() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 218, visible: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(!hostedView.restoreNotificationScrollPosition(nil))
        postScrollbar(total: 400, offset: 218, visible: 44, to: surfaceView)
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .idle)
    }

    @Test func notificationWithoutPositionDoesNotCancelActiveReplay() {
        let hostedView = GhosttySurfaceScrollView(surfaceView: ActionProbeView(frame: .zero))
        let marker = completionMarker(named: "replay-no-position")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)
        #expect(!hostedView.restoreNotificationScrollPosition(nil))
        #expect(hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
    }

    @Test func restoreWaitsForReplayCompletionBeforeRebasing() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-wait")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
        #expect(surfaceView.bindingActions.isEmpty)
        postScrollbar(total: 300, offset: 256, visible: 44, to: surfaceView)
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(completeReplay(hostedView, marker: marker, scrollbar: surfaceView.scrollbar))
        #expect(surfaceView.bindingActions == ["scroll_to_row:118"])
    }

    @Test func restoreRebasesWhenReplayCompletesWithRetainedSuffix() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-trim")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(!hostedView.completeSessionScrollbackReplay(
            ifMatches: "unrelated directory",
            scrollbarAtMarker: surfaceView.scrollbar
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        let finalScrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        #expect(completeReplay(hostedView, marker: marker, scrollbar: finalScrollbar))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
        #expect(surfaceView.scrollbar?.total == 200)
    }

    @Test func restoreUsesAuthoritativeScrollbarWhenCachedGeometryIsUnchanged() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-unchanged-scrollbar")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(completeReplay(hostedView, marker: marker, scrollbar: surfaceView.scrollbar))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
    }

    @Test func replayCompletionPublishesAuthoritativeScrollbarBeforeRestore() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-complete-before-restore")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(hostedView, marker: marker, scrollbar: surfaceView.scrollbar))
        #expect(hostedView.notificationScrollRestorePhase == .idle)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
    }

    @Test func replayCompletionSnapshotSurvivesLaterOutputUntilRestore() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-output-after-marker")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: scrollbar(total: 200, offset: 156, visible: 44)
        ))

        postScrollbar(total: 220, offset: 176, visible: 44, to: surfaceView)
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
        #expect(surfaceView.scrollbar?.total == 220)
        #expect(hostedView.sessionScrollbackReplayCompletionScrollbar?.total == 200)
    }

    @Test func preReplayNotificationUsesLiveViewportAfterResize() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-resized-after-marker")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(completeReplay(
            hostedView,
            marker: marker,
            scrollbar: scrollbar(total: 200, offset: 156, visible: 44)
        ))

        postScrollbar(total: 220, offset: 140, visible: 80, to: surfaceView)
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:0"])
    }

    @Test func restoreCancelsWhenReplayCompletionMarkerNeverArrives() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-timeout")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
        #expect(surfaceView.bindingActions.isEmpty)
        hostedView.expireSessionScrollbackReplayCompletionDeadline()
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .idle)

        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:18"])
    }

    @Test func activeReplayDeadlineStartsOnlyWhenNavigationWaits() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-active-timeout")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)
        hostedView.expireSessionScrollbackReplayCompletionDeadline()
        #expect(hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
    }

    @Test func authoritativeSnapshotFailureAbandonsPendingRestore() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-snapshot-failure")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        _ = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        #expect(completeReplay(hostedView, marker: marker, scrollbar: nil))
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .idle)
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)
    }

    @Test func panelConsumesOwnedReplayCompletionMarker() {
        let workspaceID = UUID()
        let surface = TerminalSurface(
            tabId: workspaceID,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let panel = TerminalPanel(workspaceId: workspaceID, surface: surface)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-scrollback-test.txt")
        let marker = SessionScrollbackReplayCompletionMarker(fileURL: fileURL)

        panel.adoptOwnedSessionScrollbackReplayArtifact(fileURL)
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
        #expect(!panel.hostedView.completeSessionScrollbackReplay(
            ifMatches: "/tmp",
            scrollbarAtMarker: panel.hostedView.surfaceView.scrollbar
        ))
        #expect(panel.hostedView.completeSessionScrollbackReplay(
            ifMatches: marker.reportedDirectory,
            scrollbarAtMarker: GhosttyScrollbar(c: ghostty_action_scrollbar_s())
        ))
        #expect(panel.hostedView.notificationScrollRestorePhase == .idle)
        #expect(SessionScrollbackReplayCompletionMarker.isReservedReportedDirectory(marker.reportedDirectory))
    }

    @Test func pasteTextBoxAndPointerInputCancelPendingRestore() throws {
        let workspaceID = UUID()
        let surface = TerminalSurface(
            tabId: workspaceID,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let panel = TerminalPanel(workspaceId: workspaceID, surface: surface)
        let marker = completionMarker(named: "replay-input")

        panel.hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        _ = panel.hostedView.surfaceView.prepareSurfaceForPaste(reason: "test")
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
        #expect(panel.hostedView.sessionScrollbackReplayCompletionDeadlineTimer == nil)

        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        _ = surface.sendText("textbox submission")
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))

        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        let pointerEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        panel.hostedView.surfaceView.mouseDown(with: pointerEvent)
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))

        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        surface.mobileScroll(deltaLines: 1, col: 0, row: 0)
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))

        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        surface.mobileClick(col: 0, row: 0)
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
    }

    @Test func notificationNavigationShortcutReleaseDoesNotCancelPendingRestore() throws {
        let workspaceID = UUID()
        let surface = TerminalSurface(
            tabId: workspaceID,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let panel = TerminalPanel(workspaceId: workspaceID, surface: surface)
        let marker = completionMarker(named: "replay-shortcut-release")
        panel.hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )

        let shortcutKeyUp = try #require(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "u",
            charactersIgnoringModifiers: "u",
            isARepeat: false,
            keyCode: 32
        ))
        panel.hostedView.surfaceView.keyUp(with: shortcutKeyUp)
        #expect(panel.hostedView.notificationScrollRestorePhase == .pending(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400),
            sessionScrollbackReplayCompletionMarker: marker
        ))

        let commandRelease = try #require(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0.001,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 55
        ))
        panel.hostedView.surfaceView.flagsChanged(with: commandRelease)
        #expect(panel.hostedView.notificationScrollRestorePhase == .pending(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400),
            sessionScrollbackReplayCompletionMarker: marker
        ))
    }

    @Test func mutatingBindingActionAutomationCancelsPendingRestore() {
        let workspaceID = UUID()
        let surface = TerminalSurface(
            tabId: workspaceID,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let panel = TerminalPanel(workspaceId: workspaceID, surface: surface)
        let marker = completionMarker(named: "replay-binding-action")
        panel.hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        _ = panel.hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )

        _ = panel.performBindingAction("clear_screen")
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
    }

    @Test func userWheelInputCancelsPendingRestore() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 400, offset: 218, visible: 0)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: surfaceView)
        postScrollbar(total: 400, offset: 218, visible: 44, to: surfaceView)
        #expect(surfaceView.bindingActions.isEmpty)
    }

    func makeHostedView(total: UInt64, offset: UInt64, visible: UInt64) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: total, offset: offset, visible: visible)
        return GhosttySurfaceScrollView(surfaceView: surfaceView)
    }

    func scrollbar(total: UInt64, offset: UInt64, visible: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: total, offset: offset, len: visible))
    }

    func postScrollbar(total: UInt64, offset: UInt64, visible: UInt64, to view: GhosttyNSView) {
        let value = scrollbar(total: total, offset: offset, visible: visible)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: view,
            userInfo: [GhosttyNotificationKey.scrollbar: value]
        )
    }

    func completionMarker(named name: String) -> SessionScrollbackReplayCompletionMarker {
        SessionScrollbackReplayCompletionMarker(fileURL: URL(fileURLWithPath: "/tmp/\(name).txt"))
    }

    func completeReplay(
        _ hostedView: GhosttySurfaceScrollView,
        marker: SessionScrollbackReplayCompletionMarker,
        scrollbar: GhosttyScrollbar?,
        rowSpaceRevision: UInt64 = 0
    ) -> Bool {
        hostedView.completeSessionScrollbackReplay(
            ifMatches: marker.reportedDirectory,
            scrollbarAtMarker: scrollbar,
            scrollbarRevisionAtMarker: rowSpaceRevision
        )
    }

}
