import AppKit
import Bonsplit
import QuartzCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reads a drop-zone overlay's geometry animations the way Core Animation
/// composites them, so tests can check what the first frame of a slide shows.
@MainActor
enum DropZoneOverlaySlideProbe {
    private static let geometryKeyPaths: Set<String> = [
        "position", "bounds", "bounds.origin", "bounds.size", "frame", "frameOrigin", "frameSize",
    ]

    static func geometryAnimations(on view: NSView) -> [CAPropertyAnimation] {
        guard let layer = view.layer else { return [] }
        return (layer.animationKeys() ?? []).compactMap { key in
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation,
                  let keyPath = animation.keyPath,
                  geometryKeyPaths.contains(keyPath) else { return nil }
            return animation
        }
    }

    /// The frame drawn while every geometry animation is at its start: the
    /// model frame plus each additive offset. Nil unless the geometry animates
    /// additively through `position` and `bounds.size`.
    static func renderedStartFrame(of view: NSView) -> CGRect? {
        guard let layer = view.layer else { return nil }
        let animations = geometryAnimations(on: view)
        guard !animations.isEmpty else { return nil }
        var positionOffset = CGPoint.zero
        var sizeOffset = CGSize.zero
        for animation in animations {
            guard let animation = animation as? CABasicAnimation,
                  animation.isAdditive,
                  let keyPath = animation.keyPath,
                  let from = animation.fromValue as? NSValue else { return nil }
            switch keyPath {
            case "position":
                positionOffset.x += from.pointValue.x
                positionOffset.y += from.pointValue.y
            case "bounds.size":
                sizeOffset.width += from.sizeValue.width
                sizeOffset.height += from.sizeValue.height
            default:
                return nil
            }
        }
        // A layer's position is its origin plus anchorPoint × size, for the
        // model and the rendered frame alike.
        let model = view.frame
        let anchor = layer.anchorPoint
        let size = CGSize(width: model.width + sizeOffset.width, height: model.height + sizeOffset.height)
        let position = CGPoint(
            x: model.minX + anchor.x * model.width + positionOffset.x,
            y: model.minY + anchor.y * model.height + positionOffset.y
        )
        return CGRect(
            x: position.x - anchor.x * size.width,
            y: position.y - anchor.y * size.height,
            width: size.width,
            height: size.height
        )
    }

    static func approximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}

/// A borderless, never-ordered-in window whose content view hosts the overlay:
/// the overlay only slides while it is in a window.
@MainActor
private final class OverlayWindowHost {
    let window: NSWindow
    let container: NSView

    init(size: CGSize) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        window.contentView = container
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// Hosts a shared animator. Reduce Motion is pinned per animator, so results
/// don't depend on the Mac running them.
@MainActor
private final class OverlayAnimatorHost {
    private let windowHost: OverlayWindowHost?
    let container: NSView
    let overlay = NSView(frame: .zero)
    let animator: PaneDropZoneOverlayAnimator

    init(reduceMotion: Bool = false, inWindow: Bool = true) {
        let size = CGSize(width: 200, height: 100)
        windowHost = inWindow ? OverlayWindowHost(size: size) : nil
        container = windowHost?.container ?? NSView(frame: NSRect(origin: .zero, size: size))
        animator = PaneDropZoneOverlayAnimator(overlayView: overlay)
        animator.reducesMotion = { reduceMotion }
        container.addSubview(overlay)
    }

    func close() {
        windowHost?.close()
    }

    func frame(for zone: DropZone, in bounds: CGRect? = nil) -> CGRect {
        PaneDropRouting.overlayFrame(for: zone, in: bounds ?? container.bounds)
    }

    @discardableResult
    func setZone(_ zone: DropZone?, in bounds: CGRect? = nil) -> PaneDropZoneOverlayAnimator.Transition {
        let bounds = bounds ?? container.bounds
        return animator.setZone(
            zone,
            frameForZone: { PaneDropRouting.overlayFrame(for: $0, in: bounds) },
            ensureAttached: {},
            bringToFront: {}
        )
    }
}

@MainActor
@Suite(.serialized)
struct PaneDropZoneOverlayAnimationTests {
    private typealias Probe = DropZoneOverlaySlideProbe

    /// Checks that `overlay` sits at `target` for hit geometry and layout, and is
    /// drawn starting from `displayed` so the highlight slides instead of jumping.
    private func expectSlide(of overlay: NSView, from displayed: CGRect, to target: CGRect) throws {
        #expect(Probe.approximatelyEqual(overlay.frame, target))
        let start = try #require(Probe.renderedStartFrame(of: overlay))
        #expect(Probe.approximatelyEqual(start, displayed), "slide starts at \(start), displayed \(displayed)")
    }

    /// Checks that `overlay` jumped straight to `target` without a geometry animation.
    private func expectSnap(of overlay: NSView, to target: CGRect) {
        #expect(Probe.approximatelyEqual(overlay.frame, target))
        #expect(Probe.geometryAnimations(on: overlay).isEmpty)
    }

    @Test("Retargeting slides the overlay from the displayed zone to the new one")
    func retargetSlides() throws {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        host.setZone(.left)

        try expectSlide(of: host.overlay, from: host.frame(for: .right), to: host.frame(for: .left))
    }

    @Test("Retargeting during a slide continues from where the overlay is drawn")
    func retargetDuringSlideContinues() throws {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        host.setZone(.left)
        host.setZone(.center)

        try expectSlide(of: host.overlay, from: host.frame(for: .right), to: host.frame(for: .center))
    }

    @Test("Retargeting partway through a slide continues from the presented frame")
    func retargetMidSlideContinuesFromPresentation() throws {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        let layer = try #require(host.overlay.layer)
        // Pause the overlay's clock: slides begin at its local time, and the
        // test moves that time instead of waiting.
        layer.speed = 0
        layer.timeOffset = 10
        host.setZone(.left)
        CATransaction.flush()
        layer.timeOffset = 10.05
        CATransaction.flush()
        let presented = try #require(layer.presentation()).frame
        #expect(
            !Probe.approximatelyEqual(presented, host.frame(for: .right)) &&
                !Probe.approximatelyEqual(presented, host.frame(for: .left)),
            "50 ms into the slide the overlay is drawn at \(presented)"
        )

        host.setZone(.center)
        CATransaction.flush()
        let continued = try #require(layer.presentation()).frame
        #expect(Probe.approximatelyEqual(continued, presented), "retarget drawn at \(continued), was \(presented)")
    }

    @Test("Reduce Motion moves the overlay without sliding")
    func reduceMotionSnaps() {
        let host = OverlayAnimatorHost(reduceMotion: true)
        defer { host.close() }
        host.setZone(.right)
        host.setZone(.left)

        expectSnap(of: host.overlay, to: host.frame(for: .left))
    }

    @Test("An overlay outside a window moves without sliding")
    func windowlessRetargetSnaps() {
        let host = OverlayAnimatorHost(inWindow: false)
        host.setZone(.right)
        host.setZone(.left)

        expectSnap(of: host.overlay, to: host.frame(for: .left))
    }

    @Test("Resizing the pane keeps the same zone pinned to the new layout")
    func sameZoneReframeSnaps() {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        let resized = CGRect(x: 0, y: 0, width: 160, height: 80)
        let transition = host.setZone(.right, in: resized)

        #expect(transition == .moved)
        expectSnap(of: host.overlay, to: host.frame(for: .right, in: resized))
    }

    @Test("Resizing the pane during a slide drops the slide and pins the zone to the new layout")
    func sameZoneReframeDuringSlideSnaps() {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        host.setZone(.left)
        let resized = CGRect(x: 0, y: 0, width: 160, height: 80)
        let transition = host.setZone(.left, in: resized)

        #expect(transition == .moved)
        expectSnap(of: host.overlay, to: host.frame(for: .left, in: resized))
    }

    @Test("Hiding during a slide fades the overlay where it is drawn")
    func hideDuringSlideKeepsSlide() throws {
        let host = OverlayAnimatorHost()
        defer { host.close() }
        host.setZone(.right)
        host.setZone(.left)
        let transition = host.setZone(nil)

        #expect(transition == .hidden)
        try expectSlide(of: host.overlay, from: host.frame(for: .right), to: host.frame(for: .left))
    }

    @Test("Zone changes report what the overlay did")
    func transitions() {
        let host = OverlayAnimatorHost()
        defer { host.close() }

        #expect(host.setZone(.right) == .shown)
        #expect(!host.overlay.isHidden)
        #expect(host.setZone(.right) == .unchanged)
        #expect(host.setZone(.left) == .moved)
        #expect(host.setZone(nil) == .hidden)
        #expect(host.setZone(nil) == .unchanged)
        #expect(host.setZone(.top) == .moved)
        #expect(Probe.approximatelyEqual(host.overlay.frame, host.frame(for: .top)))
    }

    @Test("Browser drop overlay slides between zones")
    func browserRetargetSlides() throws {
        let host = OverlayWindowHost(size: CGSize(width: 200, height: 100))
        defer { host.close() }
        let container = host.container
        let slot = WindowBrowserSlotView(frame: container.bounds)
        slot.dropZoneOverlayAnimator.reducesMotion = { false }
        container.addSubview(slot)

        slot.setDropZoneOverlay(zone: .right)
        let overlay = try #require(container.subviews.first {
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        })
        let rightFrame = overlay.frame
        slot.setDropZoneOverlay(zone: .left)

        try expectSlide(of: overlay, from: rightFrame, to: CGRect(x: 4, y: 4, width: 96, height: 92))
    }

    @Test("Terminal drop overlay slides between zones")
    func terminalRetargetSlides() throws {
        let host = OverlayWindowHost(size: CGSize(width: 240, height: 120))
        defer { host.close() }
        let container = host.container
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        hostedView.frame = container.bounds
        hostedView.dropZoneOverlayAnimator.reducesMotion = { false }
        container.addSubview(hostedView)

        hostedView.setDropZoneOverlay(zone: .right)
        let rightFrame = hostedView.debugDropZoneOverlayState().frame
        hostedView.setDropZoneOverlay(zone: .left)

        let overlay = try #require(container.subviews.first { $0 is GhosttyFlashOverlayView })
        try expectSlide(
            of: overlay,
            from: rightFrame,
            to: PaneDropRouting.compactOverlayFrame(for: .left, in: hostedView.bounds.size)
        )
    }

    @Test("Resizing a terminal pane during a slide drops the slide and pins the zone to the new layout")
    func terminalResizeDuringSlideSnaps() throws {
        let host = OverlayWindowHost(size: CGSize(width: 240, height: 120))
        defer { host.close() }
        let container = host.container
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        hostedView.frame = container.bounds
        hostedView.dropZoneOverlayAnimator.reducesMotion = { false }
        container.addSubview(hostedView)

        hostedView.setDropZoneOverlay(zone: .right)
        hostedView.setDropZoneOverlay(zone: .left)
        hostedView.setFrameSize(CGSize(width: 200, height: 100))
        hostedView.needsLayout = true
        hostedView.layoutSubtreeIfNeeded()

        let overlay = try #require(container.subviews.first { $0 is GhosttyFlashOverlayView })
        expectSnap(of: overlay, to: PaneDropRouting.compactOverlayFrame(for: .left, in: hostedView.bounds.size))
    }

    /// Tab drags report their zone through the terminal's AppKit drop target, while portal
    /// reconciliation forwards SwiftUI's zone, which stays nil for those drags. A
    /// reconciliation mid-hover must not fade the highlight out until the next drag update.
    @Test("A portal refresh during a tab drag keeps the terminal drop zone shown")
    func terminalPortalRefreshKeepsTabDragZone() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let targetPanel = try #require(workspace.panels.values.first)
            let targetPane = try #require(workspace.paneId(forPanelId: targetPanel.id))
            let sourcePanel = try #require(workspace.newTerminalSurface(inPane: targetPane, focus: true))
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))

            let host = OverlayWindowHost(size: CGSize(width: 240, height: 120))
            defer { host.close() }
            let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
            hostedView.frame = host.container.bounds
            host.container.addSubview(hostedView)
            hostedView.needsLayout = true
            hostedView.layoutSubtreeIfNeeded()
            hostedView.setPaneDropContext(
                PaneDropContext(workspaceId: workspace.id, panelId: targetPanel.id, paneId: targetPane)
            )
            let dropPoint = NSPoint(x: 230, y: 60)
            let target = try #require(hostedView.paneDropTargetForDrop(at: dropPoint))

            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-1842.\(UUID().uuidString)"))
            pasteboard.clearContents()
            let registration = try #require(appDelegate.tabDragTransferRegistry.register(TabDragTransfer(
                tab: Tab(id: TabID(uuid: sourceTabId.uuid), title: "Terminal", kind: "terminal"),
                sourcePaneId: PaneID(id: targetPane.id)
            )))
            defer {
                appDelegate.tabDragTransferRegistry.end(registration)
                pasteboard.clearContents()
            }
            #expect(registration.write(to: pasteboard))
            let draggingInfo = DockPaneDropMockDraggingInfo(
                window: host.window,
                location: dropPoint,
                pasteboard: pasteboard
            )

            #expect(target.draggingEntered(draggingInfo) == .move)
            let overlay = try #require(host.container.subviews.first { $0 is GhosttyFlashOverlayView })
            #expect(!overlay.isHidden)
            let zoneFrame = overlay.frame
            // Settle the fade-in, as a hover that has lasted a moment would be.
            overlay.layer?.removeAllAnimations()
            overlay.alphaValue = 1

            // What portal reconciliation forwards for an AppKit tab drag.
            hostedView.setDropZoneOverlay(zone: nil)

            #expect(!overlay.isHidden)
            #expect(overlay.alphaValue == 1, "the highlight started fading out")
            #expect((overlay.layer?.animationKeys() ?? []).isEmpty, "the highlight started fading out")
            #expect(Probe.approximatelyEqual(overlay.frame, zoneFrame))

            // Leaving the pane hides the preview at once (PaneDropTargetIdentityTests).
            target.draggingExited(draggingInfo)
            #expect(overlay.isHidden, "leaving the pane should hide the highlight")
        }
    }
}
