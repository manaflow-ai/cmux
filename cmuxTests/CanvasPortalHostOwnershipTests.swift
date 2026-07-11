import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Canvas portal host ownership", .serialized)
struct CanvasPortalHostOwnershipTests {
    @Test
    @MainActor
    func staleCanvasUnmountLeavesReplacementPortalHostIntact() {
        let panel = TerminalPanel(workspaceId: UUID())
        let hostedView = panel.hostedView
        defer {
            hostedView.removeFromSuperview()
            panel.surface.teardownSurface()
        }

        let canvasContainer = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let staleCanvasMount = CanvasPaneContentMount(
            content: .terminal(panel),
            panelId: panel.id,
            container: canvasContainer,
            onFocusPanel: { _ in }
        )

        let replacementPortalHost = NSView(frame: canvasContainer.bounds)
        var replacementFocusCount = 0
        var replacementFlashCount = 0
        hostedView.setPortalHostHandlers(
            ownerHostId: ObjectIdentifier(replacementPortalHost),
            focusHandler: { replacementFocusCount += 1 },
            triggerFlashHandler: { replacementFlashCount += 1 }
        )
        replacementPortalHost.addSubview(hostedView)
        hostedView.setActive(true)
        hostedView.setInactiveOverlay(color: .red, opacity: 0.5, visible: true)

        staleCanvasMount.unmount()

        #expect(
            hostedView.superview === replacementPortalHost,
            "A stale Canvas unmount must not detach the replacement portal's hosted terminal"
        )
        #expect(hostedView.debugPortalActive)
        #expect(!hostedView.debugInactiveOverlayState().isHidden)

        hostedView.surfaceView.onFocus?()
        hostedView.surfaceView.onTriggerFlash?()
        #expect(replacementFocusCount == 1)
        #expect(replacementFlashCount == 1)
    }
}
