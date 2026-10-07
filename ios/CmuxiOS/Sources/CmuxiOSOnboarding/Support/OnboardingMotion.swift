import SwiftUI
import UIKit

/// Every onboarding duration, curve and spring (c10-onboarding.md section 4).
/// Springs by response and damping; Reduce Motion swaps motion for fades.
enum OnboardingMotion {
    @MainActor static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Step change and progress fill: visible end near 200 ms.
    static let step = Animation.spring(response: 0.32, dampingFraction: 0.9)
    /// Card collapse after a choice.
    static let collapse = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// Bubbles and cards appearing, a little lively.
    static let appear = Animation.spring(response: 0.3, dampingFraction: 0.82)
    /// Release after a press.
    static let release = Animation.spring(response: 0.2, dampingFraction: 0.9)
    static let fade = Animation.easeOut(duration: 0.15)
    static let fadeOut = Animation.easeOut(duration: 0.12)

    /// Slide distance of the incoming step.
    static let stepTravel: CGFloat = 28
    static let pressScale: CGFloat = 0.97

    /// The animation to use for a structural change under the current setting.
    @MainActor static func structural(_ animation: Animation) -> Animation { reduceMotion ? fade : animation }

    // Vignette (Core Animation, on the layer clock).
    static let typePerCharacter: CFTimeInterval = 0.028
    static let lineFade: CFTimeInterval = 0.18
    static let vignettePeriod: CFTimeInterval = 9.5
    static let cursorBlink: CFTimeInterval = 1.0
    static let cardRise: CGFloat = 16

    // Pair radar and celebration.
    static let radarPeriod: CFTimeInterval = 1.8
    static let checkStroke: CFTimeInterval = 0.3
    static let burstBirth: CFTimeInterval = 0.5
}
