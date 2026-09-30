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
    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage?
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any?
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            self.draggingDestinationWindow = window
            self.draggingSourceOperationMask = .copy
            self.draggingLocation = location
            self.draggedImageLocation = location
            self.draggedImage = nil
            self.draggingPasteboard = pasteboard
            self.draggingSource = nil
            self.draggingSequenceNumber = 1
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        func resetSpringLoading() {}
    }

    private func browserOverlay(in slot: WindowBrowserSlotView) -> NSView? {
        // Browser drop overlays are drawn in the slot's parent container so they
        // can cover the slot without being clipped by its bounds.
        let roots: [NSView] = [slot] + (slot.superview.map { [$0] } ?? [])
        var pending = roots.flatMap(\.subviews)
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
        slot.setPaneDropContext(BrowserPaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID()
        ))
        let target = try #require(slot.paneDropTargetForDrop(at: NSPoint(x: 120, y: 60)))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.browser-pane-exit.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/drop-exit.txt") as NSURL]))
        let dropPoint = slot.convert(NSPoint(x: 120, y: 60), to: nil)
        let dragInfo = MockDraggingInfo(window: window, location: dropPoint, pasteboard: pasteboard)

        #expect(target.draggingEntered(dragInfo) == .copy)
        #expect(browserOverlay(in: slot)?.isHidden == false)
        target.draggingExited(dragInfo)

        #expect(browserOverlay(in: slot)?.isHidden == true)
    }
}
