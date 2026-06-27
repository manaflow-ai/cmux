import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct GhosttyTerminalViewVisibilityPolicyTests {
    @Test func immediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test func immediateStateUpdateAllowedWhenBoundToCurrentHost() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    @Test func immediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        #expect(
            !GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test func immediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test func swiftUIHostGeometryCallbackUsesImmediateSyncWithoutLayoutFlush() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush(let window):
            #expect(window == 3873)
        case .skip:
            Issue.record("Window-attached host callbacks should immediately reconcile portal geometry without layout flushes")
        }
    }

    @Test func swiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            Issue.record("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }

    @Test @MainActor func canvasTerminalRenderingDrivesRendererVisibility() {
        let panel = TerminalPanel(workspaceId: UUID())
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mount = CanvasPaneContentMount(
            content: .terminal(panel),
            panelId: panel.id,
            container: container,
            onFocusPanel: { _ in }
        )

        #expect(panel.surface.isRendererPortalVisible)

        mount.setRendering(false)
        #expect(!panel.surface.isRendererPortalVisible)

        mount.setRendering(true)
        #expect(panel.surface.isRendererPortalVisible)
        #expect(panel.surface.isRendererRealized)

        mount.setRendering(false)
        #expect(!panel.surface.isRendererPortalVisible)

        mount.unmount()
        #expect(panel.surface.isRendererPortalVisible)
        #expect(panel.surface.isRendererRealized)
    }
}
