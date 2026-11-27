import UIKit

/// Moves the compose field along the shared field spring: the render core
/// samples the spring that moves the rows (`HomeController.fieldKeyframes`)
/// and this plays the samples as one UIKit keyframe animation of the
/// field's frame, laying out its capsule, text and button at every sample.
/// The timing is the render core's field token, not a CmuxiOSDesign motion
/// token: the rows and the field must share one curve.
@MainActor
enum HomeFieldSpring {
    static func animate(_ view: UIView, to new: CGRect,
                        keyframes: (duration: Double, keyTimes: [Double], frames: [CGRect])) {
        let times = keyframes.keyTimes
        let frames = keyframes.frames
        guard times.count == frames.count, times.count > 1 else {
            view.frame = new
            return
        }
        // motion-allow: keyframes sampled from the shared render-core field spring (HomeMotion token)
        UIView.animateKeyframes(withDuration: keyframes.duration, delay: 0,
                                options: [.calculationModeLinear, .beginFromCurrentState, .allowUserInteraction]) {
            for i in 1..<frames.count {
                let frame = i == frames.count - 1 ? new : frames[i]
                UIView.addKeyframe(withRelativeStartTime: times[i - 1], relativeDuration: times[i] - times[i - 1]) {
                    view.frame = frame
                    view.layoutIfNeeded()
                }
            }
        }
    }
}
