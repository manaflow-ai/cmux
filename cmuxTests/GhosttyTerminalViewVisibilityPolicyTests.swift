import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testSwiftUIHostGeometryCallbackUsesImmediateSyncWithoutLayoutFlush() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush(let window):
            XCTAssertEqual(window, 3873)
        case .skip:
            XCTFail("Window-attached host callbacks should immediately reconcile portal geometry without layout flushes")
        }
    }

    func testSwiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            XCTFail("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }

    @MainActor
    func testCanvasTerminalRenderingDrivesRendererVisibility() {
        let panel = TerminalPanel(workspaceId: UUID())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mount = CanvasPaneContentMount(
            content: .terminal(panel),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in }
        )

        XCTAssertTrue(panel.surface.isRendererPortalVisible)

        mount.setRendering(false)
        XCTAssertFalse(panel.surface.isRendererPortalVisible)

        mount.setRendering(true)
        XCTAssertTrue(panel.surface.isRendererPortalVisible)

        mount.setRendering(false)
        XCTAssertFalse(panel.surface.isRendererPortalVisible)

        mount.unmount()
        XCTAssertTrue(panel.surface.isRendererPortalVisible)
    }
}
