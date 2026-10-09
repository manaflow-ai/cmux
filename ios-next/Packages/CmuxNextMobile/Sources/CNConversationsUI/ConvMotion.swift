#if os(iOS)
import QuartzCore
import UIKit

/// A SwiftUI-style spring (`response`, `dampingFraction`), evaluated
/// analytically so display-link driven animations follow the measured
/// Messages curves exactly (reference/imessage.md §7).
struct ConvSpring: Sendable, Hashable {
    var response: Double
    var damping: Double

    static let push = ConvSpring(response: 0.28, damping: 1.0)
    static let pop = ConvSpring(response: 0.27, damping: 1.0)
    static let sendFlight = ConvSpring(response: 0.45, damping: 0.84)
    static let firstSendFlight = ConvSpring(response: 0.50, damping: 0.72)
    static let transcriptShift = ConvSpring(response: 0.30, damping: 1.0)
    static let receiptMove = ConvSpring(response: 0.33, damping: 0.94)
    static let timestampReturn = ConvSpring(response: 0.43, damping: 1.0)
    static let swipeSnap = ConvSpring(response: 0.43, damping: 1.0)
    static let pin = ConvSpring(response: 0.45, damping: 0.85)
    static let keyboard = ConvSpring(response: 0.38, damping: 1.0)
    static let pop2 = ConvSpring(response: 0.25, damping: 0.80)

    var omega: Double { 2 * .pi / response }

    /// Displacement and velocity at `t` for a unit spring released from
    /// displacement `x0` (relative to the target) with velocity `v0`.
    func state(at t: Double, x0: Double, v0: Double) -> (x: Double, v: Double) {
        let w = omega, z = damping
        if z >= 1 {
            let a = x0, b = v0 + w * x0
            let e = exp(-w * t)
            return ((a + b * t) * e, (b - w * (a + b * t)) * e)
        }
        let wd = w * (1 - z * z).squareRoot()
        let a = x0, b = (v0 + z * w * x0) / wd
        let e = exp(-z * w * t)
        let c = cos(wd * t), s = sin(wd * t)
        let x = e * (a * c + b * s)
        let v = e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s)
        return (x, v)
    }

    /// UIKit timing parameters for the same curve.
    func timing(initialVelocity: CGVector = .zero) -> UISpringTimingParameters {
        let w = omega
        return UISpringTimingParameters(mass: 1, stiffness: w * w, damping: 2 * damping * w, initialVelocity: initialVelocity)
    }
}

/// Animates a scalar along a `ConvSpring` on the display link.
@MainActor
final class SpringDriver {
    private(set) var value: CGFloat
    private(set) var velocity: CGFloat = 0
    private var target: CGFloat
    private var start: CFTimeInterval = 0
    private var x0: Double = 0
    private var v0: Double = 0
    private var spring: ConvSpring
    private var link: CADisplayLink?
    private var onUpdate: (CGFloat) -> Void
    private var completion: ((Bool) -> Void)?

    init(value: CGFloat, spring: ConvSpring, onUpdate: @escaping (CGFloat) -> Void) {
        self.value = value
        self.target = value
        self.spring = spring
        self.onUpdate = onUpdate
    }

    var isAnimating: Bool { link != nil }

    /// Springs from the current value (and velocity, unless given) to `to`.
    func animate(to: CGFloat, spring: ConvSpring? = nil, velocity: CGFloat? = nil, completion: ((Bool) -> Void)? = nil) {
        let previous = self.completion
        self.completion = nil
        previous?(false)
        if let spring { self.spring = spring }
        target = to
        x0 = Double(value - to)
        v0 = Double(velocity ?? self.velocity)
        self.completion = completion
        if UIAccessibility.isReduceMotionEnabled {
            set(to)
            finish(true)
            return
        }
        start = CACurrentMediaTime()
        if link == nil {
            let l = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    /// Jumps to `v` without animating, cancelling any running animation.
    func set(_ v: CGFloat) {
        link?.invalidate()
        link = nil
        value = v
        target = v
        velocity = 0
        onUpdate(v)
    }

    func stop() {
        link?.invalidate()
        link = nil
        let c = completion
        completion = nil
        c?(false)
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let t = l.targetTimestamp - start
        let s = spring.state(at: max(0, t), x0: x0, v0: v0)
        value = target + CGFloat(s.x)
        velocity = CGFloat(s.v)
        let scale = max(abs(x0), 1)
        if abs(s.x) < 0.001 * scale + 0.0005, abs(s.v) < 0.01 * scale + 0.005 {
            value = target
            velocity = 0
            onUpdate(value)
            l.invalidate()
            link = nil
            finish(true)
            return
        }
        onUpdate(value)
    }

    private func finish(_ done: Bool) {
        let c = completion
        completion = nil
        c?(done)
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: SpringDriver?
    init(_ owner: SpringDriver) { self.owner = owner }
    @objc func tick(_ l: CADisplayLink) {
        guard let owner else { l.invalidate(); return }
        owner.tick(l)
    }
}

/// Runs `body(progress)` from 0 to 1 over a fixed duration on the display
/// link (linear in time; callers shape it). Used for the short timed holds
/// and fades the reference measured in milliseconds.
@MainActor
final class TimedDriver {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private let duration: CFTimeInterval
    private let body: (CGFloat) -> Void
    private var completion: (() -> Void)?

    init(duration: CFTimeInterval, body: @escaping (CGFloat) -> Void) {
        self.duration = duration
        self.body = body
    }

    func run(completion: (() -> Void)? = nil) {
        self.completion = completion
        start = CACurrentMediaTime()
        let l = CADisplayLink(target: TimedProxy(self), selector: #selector(TimedProxy.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        body(0)
    }

    func cancel() {
        link?.invalidate()
        link = nil
        completion = nil
    }

    fileprivate func tick(_ l: CADisplayLink) {
        let p = min(1, (l.targetTimestamp - start) / max(duration, 0.001))
        body(CGFloat(p))
        if p >= 1 {
            l.invalidate()
            link = nil
            let c = completion
            completion = nil
            c?()
        }
    }
}

@MainActor
private final class TimedProxy: NSObject {
    weak var owner: TimedDriver?
    init(_ owner: TimedDriver) { self.owner = owner }
    @objc func tick(_ l: CADisplayLink) {
        guard let owner else { l.invalidate(); return }
        owner.tick(l)
    }
}

@inline(__always) func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}
#endif
