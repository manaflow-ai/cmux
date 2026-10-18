#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// One pinch sample in the browser screen's coordinate space.
struct PinchSample: Equatable {
    enum Phase: Equatable { case began, changed, ended }
    var phase: Phase
    /// Finger distance relative to the gesture's start.
    var scale: CGFloat
    /// Midpoint between the fingers.
    var centroid: CGPoint
    var time: CFTimeInterval
}

/// A UIKit pinch recognizer attached to the whole browser screen. It never
/// cancels or delays touches, so the page, the grid's scroll view and the
/// start page keep getting theirs; the screen decides per gesture whether
/// the pinch drives the tab zoom.
struct ZoomPinchGesture: UIGestureRecognizerRepresentable {
    var onSample: (PinchSample) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        let g = UIPinchGestureRecognizer()
        g.cancelsTouchesInView = false
        g.delaysTouchesBegan = false
        g.delaysTouchesEnded = false
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPinchGestureRecognizer, context: Context) {
        let phase: PinchSample.Phase
        switch g.state {
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        let c = context.converter.location(in: .named(browserScreenSpace))
        onSample(PinchSample(phase: phase, scale: g.scale, centroid: c, time: CACurrentMediaTime()))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Bookkeeping for one pinch (reference type: updates must not re-render).
@MainActor
final class ZoomPinchSession {
    enum Decision { case pending, engaged, rejected }
    /// Pinch-in past this (relative scale) drives the zoom.
    static let engageIn: CGFloat = 0.96
    /// Pinch-out on a grid card past this opens it.
    static let engageOut: CGFloat = 1.04
    /// The decision window from the gesture's start.
    static let decisionWindow: CFTimeInterval = 0.04

    var decision: Decision = .pending
    var start: PinchSample?
    /// When the finger distance first changed (the decision window starts here).
    var movementStart: CFTimeInterval?
    var startRect: CGRect = .zero
    var startedFromOverview = false
    var tracker: PinchTracker?
    /// Recent (time, progress, offset) for the release velocity.
    var history: [(t: CFTimeInterval, p: Double, o: CGVector)] = []

    func reset() {
        decision = .pending
        start = nil
        movementStart = nil
        tracker = nil
        history = []
    }

    func record(_ t: CFTimeInterval, _ p: Double, _ o: CGVector) {
        history.append((t, p, o))
        if history.count > 12 { history.removeFirst(history.count - 12) }
    }

    /// Velocity over the last ~40 ms of samples (a window, not a filter on
    /// the tracked position: the rect itself follows the latest sample).
    func velocity() -> (p: Double, o: CGVector) {
        guard let last = history.last else { return (0, .zero) }
        let ref = history.last { last.t - $0.t >= 0.04 } ?? history.first!
        let dt = last.t - ref.t
        guard dt > 0.004 else { return (0, .zero) }
        return ((last.p - ref.p) / dt, CGVector(dx: (last.o.dx - ref.o.dx) / dt, dy: (last.o.dy - ref.o.dy) / dt))
    }
}
#endif

#if os(iOS) && DEBUG
/// A recorded-style two-finger pinch path for the DEBUG driver: scale and
/// centroid as functions of time, released while still moving.
struct DebugPinchPath {
    struct Point { var phase: PinchSample.Phase; var scale: CGFloat; var centroid: CGPoint }
    static let grabAt: CFTimeInterval = 0
    let mode: String
    let size: CGSize
    let cardCenter: CGPoint
    /// Finger spacing at the start (points).
    let spread: CGFloat = 170

    private var start: CFTimeInterval { mode == "grab" ? 0.12 : 0 }
    private var duration: CFTimeInterval {
        switch mode {
        case "page-cancel": 0.55
        case "card": 0.5
        case "grab": 0.35
        default: 0.45
        }
    }

    /// Ease-out: fingers start fast and slow down, as a real pinch does.
    private func ease(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }

    func sample(at t: CFTimeInterval) -> Point? {
        guard t >= start else { return Point(phase: .changed, scale: 1, centroid: .zero) }
        let u = t - start
        let w = size.width, h = size.height
        // Released at 85 % of the path, while the fingers are still moving.
        let releaseAt = duration * 0.85
        let x = CGFloat(min(1, u / duration))
        let k = ease(x)
        let (scale, c): (CGFloat, CGPoint)
        switch mode {
        case "page-cancel":
            scale = 1 - 0.14 * ease(min(1, x * 1.6))
            c = CGPoint(x: w * 0.5 + 20 * k, y: h * 0.5)
        case "card":
            scale = 1 + 1.3 * k
            c = CGPoint(x: cardCenter.x + (w * 0.5 - cardCenter.x) * k, y: cardCenter.y + (h * 0.5 - cardCenter.y) * k)
        case "grab":
            scale = 1 + 0.5 * k
            c = CGPoint(x: w * 0.45, y: h * 0.45 + 60 * k)
        default:
            scale = 1 - 0.55 * k
            c = CGPoint(x: w * 0.5 - w * 0.15 * k, y: h * 0.55 - h * 0.12 * k)
        }
        let phase: PinchSample.Phase = u < 1.0 / 240 ? .began : (u >= releaseAt ? .ended : .changed)
        return Point(phase: phase, scale: scale, centroid: c)
    }

    func fingers(at t: CFTimeInterval) -> [CGPoint] {
        guard let p = sample(at: t), p.centroid != .zero else { return [] }
        let d = spread * p.scale / 2
        return [CGPoint(x: p.centroid.x - d, y: p.centroid.y), CGPoint(x: p.centroid.x + d, y: p.centroid.y)]
    }
}

/// Display-clock ticks as an async sequence (CADisplayLink).
@MainActor
final class DisplayClock {
    private var link: CADisplayLink?

    func ticks() -> AsyncStream<CFTimeInterval> {
        AsyncStream { continuation in
            let target = Target { continuation.yield($0.targetTimestamp) }
            let link = CADisplayLink(target: target, selector: #selector(Target.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @MainActor
    private final class Target: NSObject {
        let handler: @MainActor (CADisplayLink) -> Void
        init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
        @objc func fire(_ link: CADisplayLink) { handler(link) }
    }
}
#endif
