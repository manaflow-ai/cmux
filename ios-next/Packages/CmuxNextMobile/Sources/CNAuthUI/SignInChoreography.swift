import CoreGraphics
import Foundation

/// Timing and geometry of the launch → sign-in choreography.
///
/// Values come from `ios-next/reference/claude-onboarding.md` (frame-measured
/// on a real iPhone 17 Pro Max recording): one critically damped spring with a
/// 0.19 s response moves the brand lockup into the header while every other
/// element fades in on a 0.23 s spring, all starting on the same frame; the
/// illustration animates on twelves (12 fps). Geometry is in points for the
/// 440 x 956 pt Pro Max screen and scales with the container elsewhere.
struct SignInChoreography: Sendable {
    // MARK: Intro (launch frame → sign-in options)

    /// Launch frame on screen before the cursor appears.
    var cursorAppearsAt: TimeInterval = 0.12
    /// First typed character of the wordmark, then one per `keystroke`.
    var firstKeystrokeAt: TimeInterval = 0.20
    var keystroke: TimeInterval = 0.07
    /// The hand-off (T0): lockup flies to the header, content fades in.
    var handoffAt: TimeInterval = 0.62
    /// Lockup spring (reference fit: response 0.192 s, damping 1.00).
    var lockupResponse: TimeInterval = 0.19
    var lockupDamping: Double = 1.0
    /// Content opacity spring (reference fit: 0.222–0.238 s, damping 0.88–0.92).
    var revealResponse: TimeInterval = 0.23
    var revealDamping: Double = 0.9
    /// Reduce Motion: plain cross-fade instead of the flight.
    var reducedMotionFade: TimeInterval = 0.2

    // MARK: Geometry (440 x 956 pt reference screen)

    /// Wordmark size on the launch frame; the header shows it at `headerScale`.
    var launchWordmarkSize: CGFloat = 34
    /// Mark (chevron) height on the launch frame. The launch image
    /// (`LaunchMark` in the app's asset catalog) is drawn at exactly this size.
    var launchMarkSize = CGSize(width: 28, height: 40)
    /// Header scale (reference: 39.7 → 23.3 pt, 0.587).
    var headerScale: CGFloat = 0.587
    /// Header lockup centre, below the top safe-area inset (reference: 82 − 62).
    var headerCenterBelowSafeTop: CGFloat = 20
    /// Gap between mark and wordmark at launch size.
    var lockupSpacing: CGFloat = 12

    // MARK: Steps (methods ↔ email ↔ code)

    /// Forward and back step transitions.
    var stepResponse: TimeInterval = 0.42
    var stepDamping: Double = 0.88
    /// Delay between consecutive elements of a step's entrance.
    var stagger: TimeInterval = 0.035
    /// Distance and blur of an element entering or leaving a step.
    var stepTravel: CGFloat = 28
    var stepBlur: CGFloat = 8

    /// Press feedback (reference: 408 → 404 pt, 0.990; release ≈ 0.33 s).
    var pressScale: CGFloat = 0.99
    var releaseResponse: TimeInterval = 0.33

    /// Code cells: per-character drop-in and the verifying wave.
    var cellDropResponse: TimeInterval = 0.28
    var cellDropDamping: Double = 0.62
    var waveStagger: TimeInterval = 0.06

    /// Success: the sign-in root leaves toward the app.
    var exitResponse: TimeInterval = 0.5

    /// Illustration frame rate (reference: 12 fps, changes every 5th 60 Hz frame).
    var illustrationFPS: Double = 12

    static let standard = SignInChoreography()

    /// Seconds from intro start at which the `index`-th wordmark character lands.
    func keystrokeTime(_ index: Int) -> TimeInterval {
        firstKeystrokeAt + Double(index) * keystroke
    }
}
