@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    /// Un-zooming rebuilds every pane host. Until the split's new hosts reach
    /// the window, the zoomed terminal's only anchor is the retired zoom host,
    /// whose frame belongs to a layout that no longer exists. Keeping the
    /// terminal on screen there draws it over the restored grid.
    @MainActor
    func testSplitUnzoomNeverKeepsTerminalAtRetiredZoomFrame() async throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        layoutResizeTestWindow(window)
        let contentView = try XCTUnwrap(window.contentView)

        let fixture = testWorkspace ?? TerminalPortalTestWorkspace()
        testWorkspace = fixture
        let workspace = fixture.workspace
        let zoomedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotNil(workspace.newTerminalSplit(from: zoomedPanelId, orientation: .horizontal))
        let panel = try XCTUnwrap(workspace.terminalPanel(for: zoomedPanelId))

        XCTAssertTrue(workspace.toggleSplitZoom(panelId: zoomedPanelId))
        let zoomHost = NSView(frame: NSRect(x: 8, y: 8, width: 504, height: 324))
        contentView.addSubview(zoomHost)
        TerminalWindowPortalRegistry.bind(hostedView: panel.hostedView, to: zoomHost, visibleInUI: true)
        let zoomedGeometrySettled = await waitForSettledPortalGeometry(panel.surface, anchor: zoomHost)
        XCTAssertTrue(zoomedGeometrySettled)
        XCTAssertFalse(panel.hostedView.isHidden)

        XCTAssertTrue(workspace.toggleSplitZoom(panelId: zoomedPanelId))
        XCTAssertFalse(workspace.bonsplitController.isSplitZoomed)
        // SwiftUI dismantles the zoom host; the split's hosts are not in the
        // window yet.
        zoomHost.removeFromSuperview()
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        let stillShowsZoomFrame =
            !panel.hostedView.isHidden &&
            panel.hostedView.window === window &&
            panel.hostedView.frame.size == zoomHost.frame.size
        XCTAssertFalse(
            stillShowsZoomFrame,
            "After un-zoom the portal must not keep the terminal visible at the retired zoom host's full-size frame"
        )
        withExtendedLifetime((panel, zoomHost)) {}
    }
}
