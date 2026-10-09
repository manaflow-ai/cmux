import CmuxTerminalRenderCore
import Foundation
import QuartzCore
import UIKit

/// The only display link of a terminal view. It runs while a scroll, its
/// deceleration or a pinch animates and stops itself when `onFrame` returns
/// false; output frames never use it (they are drawn on change). Its range
/// asks for 120 Hz on ProMotion, 30 when the device is constrained.
@MainActor
final class TerminalGestureFrameLink {
    private var link: CADisplayLink?
    private var onFrame: ((Double) -> Bool)?
    private var lastTimestamp: CFTimeInterval?

    var isRunning: Bool { link != nil }

    /// The pacing for the current device state.
    static func pacing(for screen: UIScreen?) -> TerminalFramePacing {
        let thermal: TerminalFramePacing.Thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        return TerminalFramePacing(thermal: thermal, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                   displayMaximum: screen?.maximumFramesPerSecond ?? 60)
    }

    /// Starts (or retargets) the link. `onFrame` gets the seconds since the
    /// previous frame and returns whether to keep running.
    func start(screen: UIScreen?, onFrame: @escaping (Double) -> Bool) {
        self.onFrame = onFrame
        guard link == nil else { return }
        let range = Self.pacing(for: screen).gestureRange
        // wakeup-allow: display link only while a gesture or its deceleration animates; stops itself
        let made = CADisplayLink(target: Proxy(owner: self), selector: #selector(Proxy.tick(_:)))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: range.minimum, maximum: range.maximum,
                                                        preferred: range.preferred)
        made.add(to: .main, forMode: .common)
        link = made
        lastTimestamp = nil
    }

    func stop() {
        link?.invalidate()
        link = nil
        onFrame = nil
        lastTimestamp = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        guard let onFrame, onFrame(dt) else { return stop() }
    }

    /// Breaks the display link's strong reference to its target.
    /// The display link calls it on the main run loop.
    @MainActor
    private final class Proxy: NSObject {
        weak var owner: TerminalGestureFrameLink?
        init(owner: TerminalGestureFrameLink) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}
