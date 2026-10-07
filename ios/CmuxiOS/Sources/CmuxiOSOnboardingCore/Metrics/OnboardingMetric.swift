import Foundation

/// What onboarding measures (c10-onboarding.md section 6). Step names and
/// choices only; never user data.
public enum OnboardingMetric: Hashable, Sendable {
    case stepShown(OnboardingStep, index: Int, total: Int)
    case stepFinished(OnboardingStep, outcome: StepOutcome, duration: Duration)
    case choice(OnboardingStep, value: String)
    case finished(duration: Duration, paired: Bool, mode: OnboardingMode)
}
