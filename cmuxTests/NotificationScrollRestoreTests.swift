import Foundation
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
    private final class ActionProbeView: GhosttyNSView {
        private(set) var bindingActions: [String] = []
        var frameSourceGeneration: UInt64?

        override func performBindingAction(_ action: String, recordsExplicitInput: Bool) -> Bool {
            bindingActions.append(action)
            return true
        }

        override func currentRenderedFrameSourceGeneration() -> UInt64 {
            frameSourceGeneration ?? super.currentRenderedFrameSourceGeneration()
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

    @Test func targetClampsWhenHistoryIsTrimmed() {
        let hostedView = makeHostedView(total: 200, offset: 156, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ) == .absoluteRow(156))
    }

    @Test func targetSupportsLegacyRowOnlyPosition() {
        let hostedView = makeHostedView(total: 400, offset: 218, visible: 44)
        #expect(hostedView.notificationScrollRestoreTarget(
            TerminalNotificationScrollPosition(row: 138)
        ) == .absoluteRow(218))
    }

    @Test func restoreClampsWhenHistoryIsPermanentlyTrimmed() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
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

    @Test func restoreWaitsForCapturedRowsDuringReplay() {
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
        #expect(surfaceView.bindingActions == ["scroll_to_row:218"])
    }

    @Test func restoreClampsWhenReplayCompletesWithTrimmedHistory() {
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
        surfaceView.enqueueScrollbarUpdate(scrollbar(total: 100, offset: 56, visible: 44))
        #expect(!hostedView.completeSessionScrollbackReplay(
            ifMatches: "unrelated directory"
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.completeSessionScrollbackReplay(
            ifMatches: marker.reportedDirectory
        ))
        #expect(surfaceView.flushPendingScrollbarIfAvailable())
        #expect(surfaceView.bindingActions.isEmpty)
        surfaceView.enqueueScrollbarUpdate(scrollbar(total: 200, offset: 156, visible: 44))
        #expect(surfaceView.flushPendingScrollbarIfAvailable())
        postRenderedFrame(to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
    }

    @Test func restoreUsesFinalScrollbarWhenMarkerFrameDoesNotChangeIt() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-unchanged-scrollbar")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
        postRenderedFrame(to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
    }

    @Test func replayCompletionBeforeRestoreKeepsRendererBarrier() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-complete-before-restore")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
        #expect(hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayCompleted)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
        #expect(surfaceView.bindingActions.isEmpty)
        postRenderedFrame(to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
    }

    @Test func replayCompletionBeforeArtifactAdoptionIsPreserved() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-complete-before-adoption")
        #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        #expect(hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayCompleted)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.sessionScrollbackReplayCompletionDeadlineTimer != nil)
        #expect(surfaceView.bindingActions.isEmpty)
        postRenderedFrame(to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
    }

    @Test func delayedPreMarkerFrameCannotCompleteRendererWait() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        surfaceView.frameSourceGeneration = 7
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-delayed-frame")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
        postRenderedFrame(generation: 7, to: surfaceView)
        #expect(surfaceView.bindingActions.isEmpty)
        postRenderedFrame(generation: 8, to: surfaceView)
        #expect(surfaceView.bindingActions == ["scroll_to_row:156"])
    }

    @Test func hostedViewDeinitReleasesRendererWaitResources() {
        #expect(!GhosttyApp.renderedFrameNotificationDemand.isActive)
        weak var weakHostedView: GhosttySurfaceScrollView?
        autoreleasepool {
            let surfaceView = ActionProbeView(frame: .zero)
            surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
            let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
            let marker = completionMarker(named: "replay-deinit")
            hostedView.beginSessionScrollbackReplay(completionMarker: marker)
            _ = hostedView.restoreNotificationScrollPosition(
                TerminalNotificationScrollPosition(row: 138, totalRows: 400)
            )
            #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
            #expect(GhosttyApp.renderedFrameNotificationDemand.isActive)
            weakHostedView = hostedView
        }
        #expect(weakHostedView == nil)
        #expect(!GhosttyApp.renderedFrameNotificationDemand.isActive)
    }

    @Test func restoreCancelsWhenReplayCompletionMarkerNeverArrives() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 100, offset: 56, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-timeout")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)

        #expect(hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        ))
        #expect(surfaceView.bindingActions.isEmpty)
        hostedView.expireSessionScrollbackReplayCompletionDeadline()
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayActive(marker))
    }

    @Test func restoreCancelsWhenPostMarkerFrameNeverArrives() {
        let surfaceView = ActionProbeView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: 200, offset: 156, visible: 44)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        let marker = completionMarker(named: "replay-frame-timeout")
        hostedView.beginSessionScrollbackReplay(completionMarker: marker)
        _ = hostedView.restoreNotificationScrollPosition(
            TerminalNotificationScrollPosition(row: 138, totalRows: 400)
        )
        #expect(hostedView.completeSessionScrollbackReplay(ifMatches: marker.reportedDirectory))
        #expect(GhosttyApp.renderedFrameNotificationDemand.isActive)

        hostedView.expireSessionScrollbackReplayCompletionDeadline()
        #expect(surfaceView.bindingActions.isEmpty)
        #expect(hostedView.notificationScrollRestorePhase == .idle)
        #expect(!GhosttyApp.renderedFrameNotificationDemand.isActive)
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
            ifMatches: "/tmp"
        ))
        #expect(panel.hostedView.completeSessionScrollbackReplay(
            ifMatches: marker.reportedDirectory
        ))
        #expect(panel.hostedView.notificationScrollRestorePhase == .sessionScrollbackReplayCompleted)
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

    private func makeHostedView(total: UInt64, offset: UInt64, visible: UInt64) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: .zero)
        surfaceView.scrollbar = scrollbar(total: total, offset: offset, visible: visible)
        return GhosttySurfaceScrollView(surfaceView: surfaceView)
    }

    private func scrollbar(total: UInt64, offset: UInt64, visible: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(c: ghostty_action_scrollbar_s(total: total, offset: offset, len: visible))
    }

    private func postScrollbar(total: UInt64, offset: UInt64, visible: UInt64, to view: GhosttyNSView) {
        let value = scrollbar(total: total, offset: offset, visible: visible)
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: view,
            userInfo: [GhosttyNotificationKey.scrollbar: value]
        )
    }

    private func postRenderedFrame(generation: UInt64? = nil, to view: GhosttyNSView) {
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: view,
            userInfo: [GhosttyNotificationKey.renderedFrameGeneration: generation ?? view.currentRenderedFrameSourceGeneration() + 1]
        )
    }

    private func completionMarker(named name: String) -> SessionScrollbackReplayCompletionMarker {
        SessionScrollbackReplayCompletionMarker(fileURL: URL(fileURLWithPath: "/tmp/\(name).txt"))
    }

}
