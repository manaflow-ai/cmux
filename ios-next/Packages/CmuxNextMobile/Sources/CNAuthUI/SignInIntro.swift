#if os(iOS)
import SwiftUI

/// The intro's state at a point in time: a pure function of the seconds since
/// the intro started, so the choreography is deterministic and testable.
///
/// 0 s: the launch frame (mark alone, centred, identical to the launch image).
/// Cursor at 0.12 s, "cmux" typed 0.20–0.41 s, hand-off (T0) at 0.62 s: the
/// lockup springs to the header (response 0.19 s, critically damped) while
/// every other element fades in on a 0.23 s spring, all on the same frame.
struct SignInIntroState: Equatable {
    var typedCount: Int
    var showsCursor: Bool
    /// Lockup flight from the launch position (0) to the header (1).
    var flight: Double
    /// Opacity of everything except the lockup.
    var reveal: Double
    /// Lockup opacity (only dips under Reduce Motion's cross-fade).
    var lockupOpacity: Double
    /// The hand-off has happened (the illustration starts here).
    var handedOff: Bool
    /// Every value has settled; the timeline can stop.
    var finished: Bool

    static let launch = SignInIntroState(typedCount: 0, showsCursor: false, flight: 0, reveal: 0, lockupOpacity: 1,
                                         handedOff: false, finished: false)
    static let settled = SignInIntroState(typedCount: CmuxLockup.word.count, showsCursor: false, flight: 1, reveal: 1,
                                          lockupOpacity: 1, handedOff: true, finished: true)

    init(typedCount: Int, showsCursor: Bool, flight: Double, reveal: Double, lockupOpacity: Double, handedOff: Bool, finished: Bool) {
        self.typedCount = typedCount
        self.showsCursor = showsCursor
        self.flight = flight
        self.reveal = reveal
        self.lockupOpacity = lockupOpacity
        self.handedOff = handedOff
        self.finished = finished
    }

    init(elapsed t: TimeInterval, reduceMotion: Bool, choreography c: SignInChoreography = .standard) {
        let word = CmuxLockup.word.count
        let sinceHandoff = t - c.handoffAt
        if reduceMotion {
            // No typing and no flight: fade the centred mark out, then the
            // settled screen in.
            let half = c.reducedMotionFade / 2
            let before = sinceHandoff < half
            self.init(
                typedCount: before ? 0 : word, showsCursor: false, flight: before ? 0 : 1,
                reveal: min(1, max(0, (sinceHandoff - half) / half)),
                lockupOpacity: before ? 1 - min(1, max(0, sinceHandoff / half)) : min(1, (sinceHandoff - half) / half),
                handedOff: sinceHandoff >= 0, finished: sinceHandoff >= c.reducedMotionFade)
            return
        }
        var typed = 0
        for index in 0..<word where t >= c.keystrokeTime(index) { typed = index + 1 }
        let lockup = Spring(response: c.lockupResponse, dampingRatio: c.lockupDamping)
        let reveal = Spring(response: c.revealResponse, dampingRatio: c.revealDamping)
        let flight = sinceHandoff <= 0 ? 0 : lockup.value(target: 1.0, time: sinceHandoff)
        let opacity = sinceHandoff <= 0 ? 0 : reveal.value(target: 1.0, time: sinceHandoff)
        let settle = max(lockup.settlingDuration, reveal.settlingDuration)
        self.init(typedCount: typed, showsCursor: t >= c.cursorAppearsAt && sinceHandoff < 0,
                  flight: flight, reveal: min(1, max(0, opacity)), lockupOpacity: 1,
                  handedOff: sinceHandoff >= 0, finished: sinceHandoff >= settle)
    }
}
#endif
