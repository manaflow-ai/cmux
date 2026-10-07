import Foundation

/// How onboarding ended, for the app to route on.
public struct OnboardingResult: Hashable, Sendable {
    /// The Mac paired during onboarding, if any.
    public var pairedMacName: String?

    public init(pairedMacName: String?) {
        self.pairedMacName = pairedMacName
    }
}
