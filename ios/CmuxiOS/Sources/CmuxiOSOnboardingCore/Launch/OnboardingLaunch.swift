import Foundation

/// How this launch treats onboarding.
public enum OnboardingLaunch: Hashable, Sendable {
    /// Automation (dogfood, UI tests, previews): never show, never write.
    case skip
    /// DEBUG `CMUX_IOS_ONBOARDING=1`: a fresh run in memory, optionally from a step.
    case fresh(start: OnboardingStep?)
    /// The normal path: resume the stored progress.
    case stored(start: OnboardingStep?)
}
