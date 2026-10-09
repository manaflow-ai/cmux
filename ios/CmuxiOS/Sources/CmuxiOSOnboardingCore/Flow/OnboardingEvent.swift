import Foundation

/// Input to `OnboardingFlow.send(_:)`.
public enum OnboardingEvent: Hashable, Sendable {
    /// The current step's primary action finished.
    case advance
    case back
    /// The header's Skip on a tour page: straight to sign-in.
    case skipIntro
    /// Not Now / Skip / Set Up Later on an optional step.
    case skipStep
    /// Auth, a permission or the device registry changed.
    case contextChanged(OnboardingContext)
}
