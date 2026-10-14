#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// The grid cards' swipe-to-close offsets (shared by the grid and the
/// terminal layer, which draws the active terminal's card).
@MainActor
@Observable
final class CardSwipeState {
    /// Horizontal offset per card key.
    private(set) var offsets: [String: CGFloat] = [:]
    /// Opacity per card key (Reduce Motion crossfades).
    private(set) var opacities: [String: Double] = [:]
    /// Lift scale per card key (1.09 while dragged).
    private(set) var scales: [String: CGFloat] = [:]

    /// A copy of every swiped card, drawn by the grid over the real card.
    /// It is invisible until the swipe commits; then it flies off while the
    /// card's tab leaves the grid halfway out (Safari's count changes about
    /// 99 ms after the release). Made when the drag starts, so the fly-off
    /// animates it from its first frame (a view inserted in the same update
    /// as the animated change would not move).
    private(set) var departing: [DepartingCard] = []
    /// Copies that are flying off (visible; their real card is hidden).
    private(set) var flying: Set<String> = []
    func isDeparting(_ key: String) -> Bool { flying.contains(key) }

    func offset(_ key: String) -> CGFloat { offsets[key] ?? 0 }
    /// The card in its slot (the grid card, or the live terminal over it):
    /// hidden while its departing copy flies off.
    func opacity(_ key: String) -> Double { isDeparting(key) ? 0 : opacities[key] ?? 1 }
    /// The departing copy (Reduce Motion fades it).
    func departingOpacity(_ key: String) -> Double { flying.contains(key) ? opacities[key] ?? 1 : 0 }

    private func dropCopy(_ key: String) {
        flying.remove(key)
        departing.removeAll { $0.id == key }
    }
    func scale(_ key: String) -> CGFloat { scales[key] ?? 1 }
    /// Cards above every other card: from touch-down until their spring back
    /// or exit has finished (a lowered card slid under its neighbour while
    /// still springing back).
    private(set) var raised: Set<String> = []
    func isRaised(_ key: String) -> Bool { raised.contains(key) }

    private func spring(_ s: ZoomSpring) -> Animation { .spring(response: s.response, dampingFraction: s.damping) }

    func track(_ key: String, translation: CGFloat, reduceMotion: Bool, copy: () -> DepartingCard) {
        if !departing.contains(where: { $0.id == key }) { departing.append(copy()) }
        if !raised.contains(key) { raised.insert(key) }
        if !reduceMotion, scales[key] == nil {
            withAnimation(spring(CardSwipe.lift)) { scales[key] = CardSwipe.liftScale }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            offsets[key] = CardSwipe.offset(translation: translation)
            opacities[key] = nil
        }
    }

    /// Release: fly off and close, or spring back. A committed card keeps
    /// going left at the release speed (at least `CardSwipe.flyOffMinSpeed`),
    /// lifted and opaque, until it is past the screen edge; halfway out
    /// `close` takes its tab out of the grid (the grid reflows, the count
    /// changes) without waiting for the host. Refused: the card comes back
    /// to its slot. With Reduce Motion nothing slides after release: the
    /// card fades out where it is, or reappears at its slot with a 0.18 s
    /// fade.
    func release(_ key: String, velocity: CGFloat, card: CGRect, reduceMotion: Bool,
                 departing makeCopy: () -> DepartingCard, close: @escaping () async -> Bool) {
        let offset = offsets[key] ?? 0
        guard CardSwipe.commits(offset: offset, velocity: velocity, cardWidth: card.width) else {
            comeBack(key, reduceMotion: reduceMotion)
            return
        }
        if !departing.contains(where: { $0.id == key }) { departing.append(makeCopy()) }
        flying.insert(key)
        let finish: (Bool) -> Void = { [weak self] closed in
            guard let self, !closed else { return }
            // Refused: the tab is back in the grid; its card returns to the slot.
            self.flying.remove(key)
            self.comeBack(key, reduceMotion: reduceMotion)
        }
        let landed: () -> Void = { [weak self] in
            guard let self, self.isDeparting(key) else { return }
            self.dropCopy(key)
            // Gone for good unless a refusal brings the tab back (comeBack).
            if !self.isListed(key) {
                self.offsets[key] = nil
                self.opacities[key] = nil
                self.scales[key] = nil
                self.raised.remove(key)
            }
        }
        if reduceMotion {
            Task { finish(await close()) }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade)) { opacities[key] = 0 } completion: { landed() }
            return
        }
        let target = CardSwipe.flyOffOffset(cardMinX: card.minX, cardWidth: card.width)
        // One straight move at a constant speed, split where the tab leaves the grid.
        let total = CardSwipe.flyOffDuration(distance: target - offset, velocity: velocity)
        let f = CardSwipe.flyOffRemovalFraction
        let removalPoint = offset + (target - offset) * CGFloat(f)
        withAnimation(.linear(duration: total * f)) { offsets[key] = removalPoint } completion: { [weak self] in
            Task { finish(await close()) }
            withAnimation(.linear(duration: total * (1 - f))) { self?.offsets[key] = target } completion: { landed() }
        }
    }

    /// Whether the grid lists `key` again (a refused close put it back).
    @ObservationIgnored var isListed: (String) -> Bool = { _ in false }

    func cancel(_ key: String, reduceMotion: Bool) { comeBack(key, reduceMotion: reduceMotion) }

    /// Back to the card's slot: the snap-back and settle springs, or (Reduce
    /// Motion) a 0.18 s fade in at the slot with no movement.
    private func comeBack(_ key: String, reduceMotion: Bool) {
        if reduceMotion {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                offsets[key] = 0
                scales[key] = nil
                opacities[key] = 0
            }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade), completionCriteria: .removed) { opacities[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 {
                    self?.raised.remove(key)
                    self?.dropCopy(key)
                }
            }
        } else {
            withAnimation(spring(CardSwipe.snapBack), completionCriteria: .removed) {
                offsets[key] = 0
                opacities[key] = 1
            } completion: { [weak self] in
                // Lowered only once it is back in its slot (a new drag may
                // have started meanwhile: then it stays raised).
                if self?.offsets[key] == 0 {
                    self?.raised.remove(key)
                    self?.dropCopy(key)
                }
            }
            withAnimation(spring(CardSwipe.settle)) { scales[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.scales[key] = nil }
            }
        }
    }
}

/// A swiped card on its way off screen, drawn by the grid after its tab
/// has left the list.
struct DepartingCard: Identifiable {
    let id: String
    let item: TabItem
    let rect: CGRect
    let image: UIImage?
    let topColor: Color
    let startPage: Bool
}

enum CardSwipePhase {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

/// A horizontal pan on a card: begins only when the drag is more
/// horizontal than vertical, so a vertical drag still scrolls the grid.
struct CardSwipeGesture: UIGestureRecognizerRepresentable {
    var onPhase: (CardSwipePhase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.maximumNumberOfTouches = 1
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        // From touch-down, not from recognition: the pan's own translation
        // drops the slop (about 14 pt behind the finger; Safari's card
        // catches it up, tabs-parity-audit 3e). Window coordinates, since
        // the card under the finger moves.
        let start = context.coordinator.touchDown ?? g.location(in: nil)
        let dx = g.location(in: nil).x - start.x
        switch g.state {
        case .began, .changed: onPhase(.changed(translation: dx))
        case .ended: onPhase(.ended(translation: dx, velocity: g.velocity(in: g.view).x))
        case .cancelled, .failed: onPhase(.cancelled)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Where the finger went down, in window coordinates.
        var touchDown: CGPoint?

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }

        /// The grid's scroll view waits for this pan to fail (it fails at
        /// once for a vertical drag), so a horizontal drag is never taken by
        /// the scroller first.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
#endif
