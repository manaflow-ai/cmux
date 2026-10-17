#if os(iOS)
import Observation
import QuartzCore
import UIKit
import os

/// Runs `TabZoomState` on the display's frame clock. Views read `state`
/// (progress drives every frame of the zoom); actions mutate it through the
/// methods below, which retarget the running spring instead of queueing.
@MainActor
@Observable
final class TabZoomDriver {
    private(set) var state = TabZoomState()
    /// The cards' close buttons and titles (their own clock after 0.96).
    private(set) var chrome = CardChrome()
    @ObservationIgnored var onSettle: ((TabZoomState.Phase) -> Void)?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?
    #if DEBUG
    /// DEBUG (`CMUX_NEXT_BROWSER_ZOOM_TRACE=1`): log progress per frame.
    @ObservationIgnored private static let trace = ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_ZOOM_TRACE"] == "1"
    @ObservationIgnored private static let traceLog = Logger(subsystem: "dev.cmux.next", category: "browser.zoom")
    /// DEBUG (`CMUX_NEXT_BROWSER_REVERSE_MS=<ms>`): reverse a zoom toward the
    /// grid this long after it starts, like a second tap, for frame-exact
    /// comparison with the reversal reference recording.
    @ObservationIgnored private let debugReverseAfter: Double? =
        ProcessInfo.processInfo.environment["CMUX_NEXT_BROWSER_REVERSE_MS"].flatMap(Double.init).map { $0 / 1000 }
    @ObservationIgnored private var debugElapsed: Double = 0
    @ObservationIgnored private var debugReversed = false
    #endif
    @ObservationIgnored private lazy var proxy = DisplayLinkProxy { [weak self] link in self?.tick(link) }

    init() {
        #if DEBUG
        if Self.trace { MainStallTrace.install() }
        #endif
    }

    /// Card-width travel (points) for the reversal jump; set by the screen.
    @ObservationIgnored var span: Double = 244
    func go(toOverview: Bool) { mutate { [span] in $0.go(toOverview: toOverview, span: span) } }
    func openNewTab(spring: ZoomSpring = .newTab) { mutate { $0.openNewTab(spring: spring) } }
    func beginInteraction() { mutate { $0.beginInteraction() } }
    func updateInteraction(progress: Double, velocity: Double) { mutate { $0.updateInteraction(progress: progress, velocity: velocity) } }
    func updateInteraction(progress: Double, offset: CGVector, velocity: Double, offsetVelocity: CGVector) {
        mutate { $0.updateInteraction(progress: progress, offset: offset, velocity: velocity, offsetVelocity: offsetVelocity) }
    }
    func release(toOverview: Bool) { mutate { $0.release(toOverview: toOverview) } }
    func releaseOnSwipeUpCurve() { mutate { $0.releaseOnSwipeUpCurve() } }
    func startSwipeUp() { mutate { $0.startSwipeUp() } }
    func finishCurve() { mutate { $0.finishCurve() } }
    @discardableResult
    func endInteraction(velocity: Double, startedFromOverview: Bool) -> Bool {
        var toOverview = false
        mutate { toOverview = $0.endInteraction(velocity: velocity, startedFromOverview: startedFromOverview) }
        return toOverview
    }
    func jump(toOverview: Bool) { mutate { $0.jump(toOverview: toOverview) } }

    /// The first display frame after a curve starts from rest holds still:
    /// that frame renders the change that started it (the grid, the zoom
    /// rect, a newly selected tab's page), which took 25-60 ms in the
    /// simulator. Stepping the curve in it as well left the next frame
    /// 40-60 ms late, a visible stall in the zoom's first frames.
    @ObservationIgnored private var buildFrame = false

    private func mutate(_ change: (inout TabZoomState) -> Void) {
        let before = state.phase
        let curveBefore = state.curve
        change(&state)
        if state.phase == .animating, state.curve != nil, curveBefore == nil, before == .page || before == .overview {
            buildFrame = true
        }
        if UIAccessibility.isReduceMotionEnabled, state.phase == .animating {
            state.jump(toOverview: state.target == 1)
        }
        stepChrome(0)
        if UIAccessibility.isReduceMotionEnabled, state.phase != .animating {
            chrome.settle(onOverview: state.phase == .overview)
        }
        if state.phase == .animating || chrome.animating {
            startLink()
        } else {
            stopLink()
        }
        if state.phase != .animating, before != state.phase, state.phase == .page || state.phase == .overview { onSettle?(state.phase) }
    }

    private func stepChrome(_ dt: Double) {
        var c = chrome
        c.step(dt, progress: state.progress, headingToOverview: state.phase == .interactive || (state.headingToOverview && state.phase != .page),
               settledOnOverview: state.phase == .overview)
        if c != chrome { chrome = c }
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
                state.go(toOverview: false, span: span)
            }
        }
        #endif
        let wasAnimating = state.phase == .animating
        if buildFrame {
            buildFrame = false
            if wasAnimating { return }
        }
        let settled = wasAnimating && state.step(dt)
        stepChrome(dt)
        #if DEBUG
        if Self.trace { Self.traceLog.notice("zoom t=\(now, format: .fixed(precision: 4)) p=\(self.state.progress, format: .fixed(precision: 5)) target=\(self.state.target) title=\(self.chrome.titleOpacity, format: .fixed(precision: 3)) close=\(self.chrome.closeOpacity, format: .fixed(precision: 3))") }
        #endif
        if wasAnimating, settled || state.phase != .animating { onSettle?(state.phase) }
        if state.phase != .animating, !chrome.animating { stopLink() }
    }
}

#if DEBUG
/// DEBUG (with `CMUX_NEXT_BROWSER_ZOOM_TRACE=1`): logs every main run loop
/// pass busier than 8 ms (from wake to sleep), to tell a busy main thread
/// from a late render server when a zoom frame comes late.
@MainActor
enum MainStallTrace {
    private static var installed = false
    private static let markLog = Logger(subsystem: "dev.cmux.next", category: "browser.stall")
    static func mark(_ what: String) {
        guard installed else { return }
        markLog.notice("mark \(what, privacy: .public) at=\(CACurrentMediaTime(), format: .fixed(precision: 4))")
    }
    private static var woke: CFTimeInterval = 0
    static func install() {
        guard !installed else { return }
        installed = true
        let log = Logger(subsystem: "dev.cmux.next", category: "browser.stall")
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { woke = now; return }
            let busy = (now - woke) * 1000
            if woke > 0, busy > 8 { log.notice("stall from=\(woke, format: .fixed(precision: 4)) busy=\(busy, format: .fixed(precision: 1))ms") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
#endif

/// CADisplayLink retains its target; this breaks the cycle.
@MainActor
private final class DisplayLinkProxy: NSObject {
    let handler: @MainActor (CADisplayLink) -> Void
    init(_ handler: @escaping @MainActor (CADisplayLink) -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler(link) }
}
#endif
