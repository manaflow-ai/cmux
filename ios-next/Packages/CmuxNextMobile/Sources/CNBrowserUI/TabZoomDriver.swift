#if os(iOS)
import Observation
import QuartzCore
import UIKit

/// Runs `TabZoomState` on the display's frame clock. Views read `state`
/// (progress drives every frame of the zoom); actions mutate it through the
/// methods below, which retarget the running spring instead of queueing.
@MainActor
@Observable
final class TabZoomDriver {
    private(set) var state = TabZoomState()
    @ObservationIgnored var onSettle: ((TabZoomState.Phase) -> Void)?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    #if DEBUG
    /// DEBUG (`CMUX_NEXT_BROWSER_REVERSE_MS=<ms>`): reverse a zoom toward the
    /// grid this long after it starts, like a second tap, for frame-exact
    /// comparison with the reversal reference recording.
    @ObservationIgnored private let debugReverseAfter: Double? =
        ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_REVERSE_MS"].flatMap(Double.init).map { $0 / 1000 }
    @ObservationIgnored private var debugElapsed: Double = 0
    @ObservationIgnored private var debugReversed = false
    #endif
    @ObservationIgnored private lazy var proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }

    func go(toOverview: Bool) { mutate { $0.go(toOverview: toOverview) } }
    func start(from progress: Double, toOverview: Bool) { mutate { $0.start(from: progress, toOverview: toOverview) } }
    func beginInteraction() { mutate { $0.beginInteraction() } }
    func updateInteraction(progress: Double, velocity: Double) { mutate { $0.updateInteraction(progress: progress, velocity: velocity) } }
    @discardableResult
    func endInteraction(velocity: Double, startedFromOverview: Bool) -> Bool {
        var toOverview = false
        mutate { toOverview = $0.endInteraction(velocity: velocity, startedFromOverview: startedFromOverview) }
        return toOverview
    }
    func jump(toOverview: Bool) { mutate { $0.jump(toOverview: toOverview) } }

    private func mutate(_ change: (inout TabZoomState) -> Void) {
        let before = state.phase
        change(&state)
        if UIAccessibility.isReduceMotionEnabled, state.phase == .animating {
            state.jump(toOverview: state.target == 1)
        }
        if state.phase == .animating {
            startLink()
        } else {
            stopLink()
            if before != state.phase, state.phase == .page || state.phase == .overview { onSettle?(state.phase) }
        }
    }

    private func startLink() {
        guard link == nil else { return }
        #if DEBUG
        debugElapsed = 0
        if state.headingToOverview { debugReversed = false }
        #endif
        let l = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = nil
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        // Step to the time this frame will be shown (targetTimestamp) so the
        // first frame after a tap already moves.
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = now
        #if DEBUG
        if let after = debugReverseAfter, state.headingToOverview, !debugReversed {
            debugElapsed += dt
            if debugElapsed >= after {
                debugReversed = true
                state.go(toOverview: false)
            }
        }
        #endif
        let settled = state.step(dt)
        if settled || state.phase != .animating {
            stopLink()
            onSettle?(state.phase)
        }
    }
}

/// CADisplayLink retains its target; this breaks the cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    let handler: @MainActor (CADisplayLink) -> Void
    init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}
#endif
