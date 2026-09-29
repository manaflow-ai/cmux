import AppKit
import Bonsplit
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct PaneDropTargetIdentityTests {
    private func browserOverlay(in slot: WindowBrowserSlotView) -> NSView? {
        // The preview is a sibling so it can draw above the hosted browser.
        var pending = (slot.superview ?? slot).subviews
        while let view = pending.popLast() {
            if String(describing: type(of: view)).contains("BrowserDropZoneOverlayView") {
                return view
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    @Test("A reparented overlay snaps in its new coordinate space")
    func reparentedOverlaySnapsToNewOwner() throws {
        let firstOwner = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let secondOwner = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = secondOwner

        let overlay = NSView(frame: .zero)
        let animator = PaneDropZoneOverlayAnimator(overlayView: overlay)
        animator.reducesMotion = { false }
        firstOwner.addSubview(overlay)

        animator.setZone(
            .right,
            frameForZone: { PaneDropRouting.compactOverlayFrame(for: $0, in: firstOwner.bounds.size) },
            ensureAttached: {},
            bringToFront: {}
        )
        animator.setZone(
            .left,
            frameForZone: { PaneDropRouting.compactOverlayFrame(for: $0, in: firstOwner.bounds.size) },
            ensureAttached: {},
            bringToFront: {}
        )

        secondOwner.addSubview(overlay)
        let expected = PaneDropRouting.compactOverlayFrame(for: .center, in: secondOwner.bounds.size)
        animator.setZone(
            .center,
            frameForZone: { _ in expected },
            ensureAttached: {},
            bringToFront: {}
        )

        #expect(abs(overlay.frame.minX - expected.minX) <= 0.5)
        #expect(abs(overlay.frame.minY - expected.minY) <= 0.5)
        #expect(abs(overlay.frame.width - expected.width) <= 0.5)
        #expect(abs(overlay.frame.height - expected.height) <= 0.5)
        let geometryAnimations = overlay.layer?.animationKeys() ?? []
        #expect(geometryAnimations.allSatisfy { !$0.hasPrefix("paneDropZone.slide.") })
    }

    @Test("Terminal pane context changes clear the old preview")
    func terminalContextChangeClearsPreview() throws {
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        hostedView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostedView
        hostedView.setPaneDropContext(PaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))
        hostedView.setDropZoneOverlay(zone: .right, fromPaneDrag: true)
        #expect(!hostedView.debugDropZoneOverlayState().isHidden)

        hostedView.setPaneDropContext(PaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))

        let state = hostedView.debugDropZoneOverlayState()
        #expect(state.isHidden)
    }

    @Test("Browser pane context changes clear the old preview")
    func browserContextChangeClearsPreview() throws {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = slot
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))
        slot.setPortalDragDropZone(.right)
        #expect(browserOverlay(in: slot)?.isHidden == false)

        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))

        #expect(browserOverlay(in: slot)?.isHidden == true)
    }

    @Test("Leaving a pane hides its drag preview immediately")
    func paneDragExitHidesImmediately() throws {
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        hostedView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostedView
        hostedView.setDropZoneOverlay(zone: .left, fromPaneDrag: true)
        hostedView.setDropZoneOverlay(zone: nil, fromPaneDrag: true)

        let state = hostedView.debugDropZoneOverlayState()
        #expect(state.isHidden)
    }

    @Test("Browser pane drag exit hides its preview immediately")
    func browserPaneDragExitHidesImmediately() throws {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = slot
        slot.setPortalDragDropZone(.left)
        slot.setPortalDragDropZone(nil)

        #expect(browserOverlay(in: slot)?.isHidden == true)
    }
}
