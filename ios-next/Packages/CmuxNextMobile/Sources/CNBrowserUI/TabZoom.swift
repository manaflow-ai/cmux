import Foundation

/// A damped spring in SwiftUI's `spring(response:dampingFraction:)` terms.
struct ZoomSpring: Equatable, Sendable {
    var response: Double
    var damping: Double

    /// Page to card (tabs button), fitted to tab-zoom-device.mp4.
    static let toOverview = ZoomSpring(response: 0.33, damping: 0.91)
    /// Card to page (Done, a card, a new tab), fitted to tab-zoom-device.mp4.
    static let toPage = ZoomSpring(response: 0.335, damping: 1.0)
    /// A transition reversed while running, fitted to tab-reverse-device.mp4:
    /// the new spring starts from the current position and keeps only a fifth
    /// of the old velocity (full velocity overshoots the recording by 7 pt).
    static let reversal = ZoomSpring(response: 0.39, damping: 0.88)
    /// After a pinch is released.
    static let release = ZoomSpring(response: 0.36, damping: 0.9)
}

/// The page <-> tab overview transition as one progress value driven by an
/// interruptible spring: 0 is the full page, 1 is the tab's card in the grid.
/// Every entry point (tabs button, Done, card tap, new tab, pinch) moves the
/// same value, so a transition can be reversed or grabbed at any point and
/// the UI's interactive state is derived from it, never from flags that an
/// animation completion has to clear.
struct TabZoomState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Settled on the full page.
        case page
        /// Settled on the grid.
        case overview
        /// Spring running toward `target`.
        case animating
        /// A pinch drives `progress` directly.
        case interactive
    }

    static let velocityKeptOnReversal = 0.2
    /// Settled when within this distance of the target, moving slower than `restVelocity`.
    static let restDistance = 0.001
    static let restVelocity = 0.01

    private(set) var progress: Double = 0
    /// Progress per second.
    private(set) var velocity: Double = 0
    private(set) var target: Double = 0
    private(set) var spring: ZoomSpring = .toPage
    private(set) var phase: Phase = .page

    init(overview: Bool = false) {
        progress = overview ? 1 : 0
        target = progress
        phase = overview ? .overview : .page
    }

    /// The grid takes taps only when it is settled.
    var gridInteractive: Bool { phase == .overview }
    /// The live page takes input only when it is settled.
    var pageInteractive: Bool { phase == .page }
    /// Moving or heading to (or showing) the grid.
    var showsOverview: Bool { phase != .page }
    var headingToOverview: Bool { target == 1 }

    /// Tabs button / Done: go to `overview`, reversing a running transition
    /// from where it is.
    mutating func go(toOverview: Bool) {
        let newTarget: Double = toOverview ? 1 : 0
        switch phase {
        case .page where !toOverview, .overview where toOverview:
            return
        case .animating where newTarget == target:
            return
        case .animating:
            animate(to: newTarget, spring: .reversal, keepVelocity: Self.velocityKeptOnReversal)
        case .interactive:
            animate(to: newTarget, spring: .release, keepVelocity: 1)
        case .page, .overview:
            animate(to: newTarget, spring: toOverview ? .toOverview : .toPage, keepVelocity: 0)
        }
    }

    /// Starts a transition from an explicit progress (a new tab grows from
    /// its slot: start at 1, go to the page).
    mutating func start(from progress: Double, toOverview: Bool) {
        self.progress = progress
        velocity = 0
        animate(to: toOverview ? 1 : 0, spring: toOverview ? .toOverview : .toPage, keepVelocity: 0)
    }

    mutating func animate(to target: Double, spring: ZoomSpring, keepVelocity: Double) {
        self.target = target
        self.spring = spring
        velocity *= keepVelocity
        phase = .animating
        if isAtRest { settle() }
    }

    // MARK: Pinch

    mutating func beginInteraction() {
        phase = .interactive
        velocity = 0
    }

    /// `progress` may leave 0...1 a little (rubber band); `velocity` is progress/s.
    mutating func updateInteraction(progress: Double, velocity: Double) {
        guard phase == .interactive else { return }
        self.progress = min(1.08, max(-0.08, progress))
        self.velocity = velocity
    }

    /// Completes toward the grid past half way or when moving toward it fast
    /// enough, else springs back. Returns whether it goes to the grid.
    @discardableResult
    mutating func endInteraction(velocity: Double, startedFromOverview: Bool) -> Bool {
        guard phase == .interactive else { return target == 1 }
        self.velocity = velocity
        let projected = progress + velocity * 0.15
        let toOverview: Bool
        if abs(velocity) > 1.2 { toOverview = velocity > 0 } else { toOverview = projected > 0.5 }
        _ = startedFromOverview
        animate(to: toOverview ? 1 : 0, spring: .release, keepVelocity: 1)
        return toOverview
    }

    /// Ends an interaction or transition without animating (tab closed, reset).
    mutating func jump(toOverview: Bool) {
        progress = toOverview ? 1 : 0
        target = progress
        velocity = 0
        phase = toOverview ? .overview : .page
    }

    // MARK: Integration

    private var isAtRest: Bool {
        abs(progress - target) < Self.restDistance && abs(velocity) < Self.restVelocity
    }

    private mutating func settle() {
        progress = target
        velocity = 0
        phase = target == 1 ? .overview : .page
    }

    /// Advances the spring by `dt` seconds. Returns true when it settled in this step.
    @discardableResult
    mutating func step(_ dt: Double) -> Bool {
        guard phase == .animating, dt > 0 else { return false }
        let w = 2 * Double.pi / spring.response
        // Semi-implicit Euler in small substeps (stable for any frame time).
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 600)
            let x = progress - target
            let a = -w * w * x - 2 * spring.damping * w * velocity
            velocity += a * h
            progress += velocity * h
            remaining -= h
        }
        if isAtRest {
            settle()
            return true
        }
        return false
    }
}
