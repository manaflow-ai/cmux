public import UIKit

/// Animation choices that respect Reduce Motion.
@MainActor
public enum HomeMotion {
    public static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    public static var reduceTransparency: Bool { UIAccessibility.isReduceTransparencyEnabled }

    /// Runs `changes` with a spring, or a short fade when Reduce Motion is on.
    public static func animate(_ changes: @escaping @MainActor () -> Void, completion: (@MainActor (Bool) -> Void)? = nil) {
        if reduceMotion {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: changes, completion: { done in completion?(done) })
        } else {
            UIView.animate(springDuration: 0.35, bounce: 0.12, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: changes, completion: { done in completion?(done) })
        }
    }
}
