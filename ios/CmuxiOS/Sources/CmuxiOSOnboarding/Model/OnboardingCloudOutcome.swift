import Foundation

/// How the Cloud step's create ended; `message` is already localized.
public enum OnboardingCloudOutcome: Hashable, Sendable {
    case created
    case refused(message: String)
}
