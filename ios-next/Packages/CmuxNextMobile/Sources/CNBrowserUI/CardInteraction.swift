#if os(iOS)
import SwiftUI
import UIKit

/// One item of a card's context menu.
struct CardMenuEntry {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
}

/// A grid card's touches, in UIKit as Safari does it: tap to open, a
/// horizontal pan to swipe the card away, the system context menu on a long
/// press (the card lifts into its preview), and a drag from the lifted
/// preview to move the card to another slot.
///
/// All on one UIKit view: the pan and the context menu's long press then
/// follow UIKit's rules, so a pan past the slop fails the long press, and a
/// swipe moves from its first frame. SwiftUI's `.contextMenu` made every
/// other gesture on the card wait for its long press to fail (a slow drag
/// stood still for about 450 ms).
struct CardInteraction: UIViewRepresentable {
    /// The card's page area (the title row below it is not part of the preview).
    var card: CGSize
    var radius: CGFloat
    /// Touches here pass through (the card's close button).
    var passThrough: CGRect?
    /// Menu sections; empty: no menu.
    var menu: () -> [[CardMenuEntry]]
    /// The lifted card, laid out at `scale` x the card.
    var preview: (CGFloat) -> AnyView
    /// The item key a drag from the lifted preview carries; nil: no drag.
    var dragKey: String?
    /// The menu opened (true) or finished closing (false): the card hides
    /// under its lifted preview meanwhile (Safari; the system does not hide
    /// a card whose preview is drawn separately).
    var onMenu: (Bool) -> Void = { _ in }
    var onTap: () -> Void
    var onPan: (CardSwipePhase) -> Void
    var onDragStart: () -> Void
    var onDragEnd: () -> Void

    func makeUIView(context: Context) -> CardInteractionView {
        let v = CardInteractionView()
        let c = context.coordinator
        c.owner = self
        c.view = v
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        tap.delegate = c
        v.addGestureRecognizer(tap)
        v.addGestureRecognizer(pan)
        c.panRecognizer = pan
        v.addInteraction(UIContextMenuInteraction(delegate: c))
        let drag = UIDragInteraction(delegate: c)
        drag.isEnabled = true
        v.addInteraction(drag)
        return v
    }

    func updateUIView(_ v: CardInteractionView, context: Context) {
        context.coordinator.owner = self
        v.passThrough = passThrough
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
        var owner: CardInteraction?
        weak var view: UIView?
        weak var panRecognizer: UIPanGestureRecognizer?
        /// Where the finger went down, in window coordinates.
        private var touchDown: CGPoint?
        /// The context menu is up (or lifting): the swipe stays out.
        private var menuActive = false
        @objc func tap(_ g: UITapGestureRecognizer) { if g.state == .ended { owner?.onTap() } }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let owner else { return }
            // From touch-down, not from recognition (the slop is not lost).
            let start = touchDown ?? g.location(in: nil)
            let dx = g.location(in: nil).x - start.x
            switch g.state {
            case .began, .changed: owner.onPan(.changed(translation: dx))
            case .ended: owner.onPan(.ended(translation: dx, velocity: g.velocity(in: g.view).x))
            case .cancelled, .failed: owner.onPan(.cancelled)
            default: break
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g === panRecognizer { touchDown = touch.location(in: nil) }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return !menuActive }
            guard !menuActive else { return false }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The grid's scroll view waits for this pan to fail (it fails at
        /// once for a vertical drag).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g === panRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        // MARK: Context menu

        private func cardRect(in v: UIView) -> CGRect {
            CGRect(origin: .zero, size: owner?.card ?? v.bounds.size)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let owner, let v = view, cardRect(in: v).contains(location) else { return nil }
            let sections = owner.menu()
            guard !sections.isEmpty else { return nil }
            // No preview controller: the card itself lifts, and UIKit grows it
            // to Safari's 195.7 x 275 and places the menu where Safari does
            // (above a card low on screen, so an upward move stays in the
            // menu). A preview controller made UIKit keep the menu below and
            // push the preview up instead, over the bottom bar for a row-2
            // card, and an upward move left the menu and reordered.
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in
                let groups = sections.map { group in
                    UIMenu(options: .displayInline, children: group.map { e in
                        UIAction(title: e.title, image: UIImage(systemName: e.symbol),
                                 attributes: e.destructive ? .destructive : []) { _ in e.action() }
                    })
                }
                return UIMenu(children: groups)
            })
        }

        /// The card itself lifts (rendered at its size, with its shape),
        /// not the transparent touch view.
        private func targeted() -> UITargetedPreview? {
            guard let owner, let v = view, v.window != nil else { return nil }
            let r = cardRect(in: v)
            let host = UIHostingController(rootView: owner.preview(1))
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(origin: .zero, size: r.size)
            let params = UIPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerRadius: owner.radius)
            params.backgroundColor = .clear
            return UITargetedPreview(view: host.view, parameters: params,
                                     target: UIPreviewTarget(container: v, center: CGPoint(x: r.midX, y: r.midY)))
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? { targeted() }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? { targeted() }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            menuActive = true
            owner?.onMenu(true)
            // The card's own recognizers let go of the touch that opened the
            // menu (a swipe that began meanwhile never acts on it, and a
            // pending tap must not hold the touch the menu now tracks).
            for g in view?.gestureRecognizers ?? [] {
                g.isEnabled = false
                g.isEnabled = true
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            menuActive = false
            #if DEBUG
            MainStallTrace.mark("menu willEnd")
            #endif
            // Shown again once the preview has settled back onto it (also
            // after an action, and with no drag under way: the lift the long
            // press made for the menu is over too).
            // The owner's callbacks are taken now: an action that rebuilds
            // the card (Pin Tab makes it a pinned capsule) frees this
            // coordinator before the animation ends.
            let onMenu = owner?.onMenu, onDragEnd = owner?.onDragEnd, dragging = self.dragging
            let restore: () -> Void = {
                onMenu?(false)
                if !dragging { onDragEnd?() }
            }
            if let animator {
                animator.addCompletion(restore)
            } else {
                restore()
            }
        }

        // MARK: Drag (from the lifted preview)

        func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: any UIDragSession) -> [UIDragItem] {
            #if DEBUG
            MainStallTrace.mark("drag itemsForBeginning")
            #endif
            guard let key = owner?.dragKey else { return [] }
            return [UIDragItem(itemProvider: NSItemProvider(object: key as NSString))]
        }

        /// The dragged card: the card drawn into an image. A hosting view that
        /// is in no window has drawn nothing yet when UIKit lifts it, so the
        /// card turned into a blank rectangle under the finger.
        func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
                             session: any UIDragSession) -> UITargetedDragPreview? {
            guard let owner, let v = view, let window = v.window else { return nil }
            let r = cardRect(in: v)
            let renderer = ImageRenderer(content: owner.preview(1).frame(width: r.width, height: r.height))
            renderer.scale = window.screen.scale
            renderer.isOpaque = false
            guard let image = renderer.uiImage else { return nil }
            let iv = UIImageView(image: image)
            iv.frame = CGRect(origin: .zero, size: r.size)
            let params = UIDragPreviewParameters()
            params.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerRadius: owner.radius)
            params.backgroundColor = .clear
            return UITargetedDragPreview(view: iv, parameters: params,
                                         target: UIDragPreviewTarget(container: v, center: CGPoint(x: r.midX, y: r.midY)))
        }

        /// A drag session is under way (not just the lift a long press makes
        /// for every menu): only then is the card's slot empty.
        private var dragging = false

        /// The lift happens on every long press, also for a menu that never
        /// becomes a drag: the card hides only once a drag session begins,
        /// and shows again when it ends (it stayed hidden after every menu,
        /// re-audit 5).
        func dragInteraction(_ interaction: UIDragInteraction, sessionWillBegin session: any UIDragSession) {
            dragging = true
            owner?.onDragStart()
        }

        func dragInteraction(_ interaction: UIDragInteraction, item: UIDragItem, willAnimateCancelWith animator: any UIDragAnimating) {
            if !dragging { owner?.onDragEnd() }
        }

        func dragInteraction(_ interaction: UIDragInteraction, session: any UIDragSession, didEndWith operation: UIDropOperation) {
            dragging = false
            #if DEBUG
            MainStallTrace.mark("drag end \(operation.rawValue)")
            #endif
            owner?.onDragEnd()
        }
    }
}

final class CardInteractionView: UIView {
    var passThrough: CGRect?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let r = passThrough, r.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif
