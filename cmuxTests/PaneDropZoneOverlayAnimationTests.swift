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

@MainActor
private final class OverlayAnimatorHost {
    private let windowHost = OverlayWindowHost(size: CGSize(width: 200, height: 100))
    let overlay = NSView(frame: .zero)
    let animator: PaneDropZoneOverlayAnimator
    var container: NSView { windowHost.container }

    init() {
        animator = PaneDropZoneOverlayAnimator(overlayView: overlay)
        windowHost.container.addSubview(overlay)
    }

    func close() {
        windowHost.close()
    }

    func frame(for zone: DropZone) -> CGRect {
        PaneDropRouting.overlayFrame(for: zone, in: container.bounds)
    }

    func setZone(_ zone: DropZone?) {
        let bounds = container.bounds
        animator.setZone(
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

    @Test("Browser drop overlay slides between zones")
    func browserRetargetSlides() throws {
        let host = OverlayWindowHost(size: CGSize(width: 200, height: 100))
        defer { host.close() }
        let container = host.container
        let slot = WindowBrowserSlotView(frame: container.bounds)
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
}
