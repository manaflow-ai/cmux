#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// The grid cards' swipe-to-close offsets (shared by the grid and the
/// terminal layer, which draws the active terminal's card).
@MainActor
@Observable
final class CardSwipeState {
    /// Horizontal offset per card key, following the finger from touch-down.
    private(set) var offsets: [String: CGFloat] = [:]
    /// The part of the touch slop not caught up yet (animated to 0 over
    /// 80 ms when the drag is recognised): the card glides to the finger
    /// instead of jumping there (Safari, tabs-parity-reaudit D3).
    private(set) var catchUps: [String: CGFloat] = [:]
    /// Opacity per card key (Reduce Motion crossfades).
    private(set) var opacities: [String: Double] = [:]
    /// Lift scale per card key (1.093 while dragged).
    private(set) var scales: [String: CGFloat] = [:]

    /// Cards flying off after a committed swipe. The grid keeps drawing them
    /// (the same card view, so the exit never re-renders it) after their tab
    /// has left the list, until they are off screen.
    private(set) var departing: [DepartingCard] = []
    func isDeparting(_ key: String) -> Bool { departing.contains { $0.id == key } }

    func offset(_ key: String) -> CGFloat { (offsets[key] ?? 0) + (catchUps[key] ?? 0) }
    func opacity(_ key: String) -> Double { opacities[key] ?? 1 }
    func scale(_ key: String) -> CGFloat { scales[key] ?? 1 }
    /// Cards above every other card: from touch-down until their spring back
    /// or exit has finished (a lowered card slid under its neighbour while
    /// still springing back).
    private(set) var raised: Set<String> = []
    func isRaised(_ key: String) -> Bool { raised.contains(key) }

    /// Whether the grid lists `key` again (a refused close put it back).
    @ObservationIgnored var isListed: (String) -> Bool = { _ in false }
    /// Times the tab's removal during a fly-off (injected for tests).
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()

    /// The textbook spring for `s` (SwiftUI's `.spring(response:dampingFraction:)`
    /// renders faster and stiffer than its parameters; tabs-parity-reaudit D8).
    private func spring(_ s: ZoomSpring) -> Animation { s.animation() }

    func track(_ key: String, translation: CGFloat, reduceMotion: Bool) {
        let target = CardSwipe.offset(translation: translation)
        let first = !raised.contains(key)
        if first { raised.insert(key) }
        if !reduceMotion, scales[key] == nil {
            withAnimation(spring(CardSwipe.lift)) { scales[key] = CardSwipe.liftScale }
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if first, !reduceMotion, offsets[key] == nil {
                // Start where the card is (its slot) and glide to the finger.
                catchUps[key] = -target
            }
            offsets[key] = target
            opacities[key] = nil
        }
        if first, !reduceMotion, catchUps[key] != nil {
            withAnimation(.easeOut(duration: CardSwipe.slopCatchUp)) { catchUps[key] = 0 } completion: { [weak self] in
                if self?.catchUps[key] == 0 { self?.catchUps[key] = nil }
            }
        }
    }

    /// Release: fly off and close, or spring back. A committed card keeps
    /// going left at the release speed (at least `CardSwipe.flyOffMinSpeed`),
    /// lifted and opaque, from the release frame until it is past the
    /// screen edge; 99 ms in, `close` takes its tab out of the grid (the
    /// count changes, the grid reflows) without waiting for the host.
    /// Refused: the card comes back to its slot. A card that springs back
    /// keeps the finger's velocity into the spring. With Reduce Motion
    /// nothing slides after release: the card fades out where it is, or
    /// reappears at its slot with a 0.18 s fade.
    func release(_ key: String, velocity: CGFloat, card: CGRect, reduceMotion: Bool,
                 departing makeCopy: () -> DepartingCard, close: @escaping () async -> Bool) {
        let offset = offsets[key] ?? 0
        guard CardSwipe.commits(offset: offset, velocity: velocity, cardWidth: card.width) else {
            comeBack(key, velocity: velocity, reduceMotion: reduceMotion)
            return
        }
        departing.removeAll { $0.id == key }
        departing.append(makeCopy())
        let finish: (Bool) -> Void = { [weak self] closed in
            guard let self, !closed else { return }
            // Refused: the tab is back in the grid; its card returns to the slot.
            self.departing.removeAll { $0.id == key }
            self.comeBack(key, velocity: 0, reduceMotion: reduceMotion)
        }
        let landed: () -> Void = { [weak self] in
            guard let self, self.isDeparting(key) else { return }
            self.departing.removeAll { $0.id == key }
            // Gone for good unless a refusal brings the tab back (comeBack).
            if !self.isListed(key) {
                self.offsets[key] = nil
                self.catchUps[key] = nil
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
        // The slop catch-up ends where it is; the move is one straight line
        // at the release speed, split where the tab leaves the grid.
        let start = self.offset(key)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            catchUps[key] = nil
            offsets[key] = start
        }
        let target = CardSwipe.flyOffOffset(cardMinX: card.minX, cardWidth: card.width)
        let total = CardSwipe.flyOffDuration(distance: target - start, velocity: velocity)
        // One uninterrupted move (a second animation chained on the first
        // one's completion started 3-4 frames late).
        withAnimation(.linear(duration: total)) { offsets[key] = target } completion: { landed() }
        let clock = self.clock
        Task {
            try? await clock.sleep(for: .seconds(min(total, CardSwipe.flyOffRemovalDelay)))
            finish(await close())
        }
    }

    func cancel(_ key: String, reduceMotion: Bool) { comeBack(key, velocity: 0, reduceMotion: reduceMotion) }

    /// Back to the card's slot: the snap-back spring carrying the finger's
    /// velocity (Safari's card keeps moving 1–2 frames after a slow release)
    /// and the settle spring, or (Reduce Motion) a 0.18 s fade in at the
    /// slot with no movement.
    private func comeBack(_ key: String, velocity: CGFloat, reduceMotion: Bool) {
        let from = offset(key)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            catchUps[key] = nil
            offsets[key] = from
        }
        if reduceMotion {
            withTransaction(t) {
                offsets[key] = 0
                scales[key] = nil
                opacities[key] = 0
            }
            withAnimation(.easeInOut(duration: CardSwipe.reduceMotionFade), completionCriteria: .removed) { opacities[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.raised.remove(key) }
            }
        } else {
            let s = from > 0 ? CardSwipe.snapBackRight : CardSwipe.snapBack
            // The spring's velocity is a fraction of the change per second.
            let relative = abs(from) > 0.5 ? Double(velocity / (0 - from)) : 0
            let animation = s.animation(initialVelocity: relative)
            withAnimation(animation, completionCriteria: .removed) {
                offsets[key] = 0
                opacities[key] = 1
            } completion: { [weak self] in
                // Lowered only once it is back in its slot (a new drag may
                // have started meanwhile: then it stays raised).
                if self?.offsets[key] == 0 { self?.raised.remove(key) }
            }
            withAnimation(spring(CardSwipe.settle)) { scales[key] = 1 } completion: { [weak self] in
                if self?.offsets[key] == 0 { self?.scales[key] = nil }
            }
        }
    }
}

extension ZoomSpring {
    /// A damped oscillator with this response and damping (mass 1,
    /// stiffness (2π / response)², damping 4π · damping / response).
    func animation(initialVelocity: Double = 0) -> Animation {
        let w = 2 * Double.pi / response
        return .interpolatingSpring(mass: 1, stiffness: w * w, damping: 2 * damping * w, initialVelocity: initialVelocity)
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

        /// The card's long-press menu and drag-to-reorder interactions must
        /// not hold the swipe back: waiting for them to fail kept a slow
        /// drag's card still for about 300 ms, then it jumped to the finger
        /// (tabs-parity-reaudit D3).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            CardGestures.recognizeTogether(other: other)
        }

        /// The grid's scroll view waits for this pan to fail (it fails at
        /// once for a vertical drag), so a horizontal drag is never taken by
        /// the scroller first.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

extension CardGestures {
    /// A card's swipe and long press never run together, and neither runs
    /// with the grid's scroll: once the long press has begun (menu or
    /// reorder) the swipe cannot begin for that touch, and a swipe that
    /// began first makes the long press fail. A long-press reorder dragged
    /// left was closing the dragged tab on the drop (re-audit 2, D6b).
    static func recognizeTogether(other: UIGestureRecognizer) -> Bool {
        !(other.view is UIScrollView) && !(other is UILongPressGestureRecognizer) && !(other is UIPanGestureRecognizer)
    }
}

enum CardPressPhase {
    /// Window coordinates.
    case began(CGPoint), changed(CGPoint), ended(CGPoint), cancelled
}

/// A long press on a card (0.5 s, within 10 pt): Safari's card menu, or,
/// when the finger then moves, a drag to another slot. A plain UIKit
/// recognizer on the card itself: the system context menu held the card's
/// swipe back for about 450 ms (it waited for the menu's press to fail).
struct CardLongPressGesture: UIGestureRecognizerRepresentable {
    var onPhase: (CardPressPhase) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.5
        g.allowableMovement = 10
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        let p = g.location(in: nil)
        switch g.state {
        case .began: onPhase(.began(p))
        case .changed: onPhase(.changed(p))
        case .ended: onPhase(.ended(p))
        case .cancelled, .failed: onPhase(.cancelled)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            CardGestures.recognizeTogether(other: other)
        }
    }
}
#endif
