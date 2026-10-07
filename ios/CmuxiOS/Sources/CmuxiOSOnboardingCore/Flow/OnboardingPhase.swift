import Foundation

/// Back never crosses a phase boundary: once signed in, the tour and the
/// sign-in screen are behind the user.
public enum OnboardingPhase: String, Hashable, Sendable {
    case intro
    case setup
}
