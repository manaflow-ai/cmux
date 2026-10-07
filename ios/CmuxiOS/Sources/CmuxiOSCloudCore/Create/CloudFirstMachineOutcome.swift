import Foundation

/// How the onboarding create ended.
public enum CloudFirstMachineOutcome: Hashable, Sendable {
    case created
    /// The owner refused; the code (`cloud.plan.required`, ...) for the screen.
    case refused(code: String)
    case offline
}
