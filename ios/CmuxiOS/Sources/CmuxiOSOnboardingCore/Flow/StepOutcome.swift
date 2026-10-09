import Foundation

/// How the user left a step they saw. Steps passed over because their
/// condition was already met record nothing.
public enum StepOutcome: String, Codable, Hashable, Sendable {
    case completed
    case skipped
}
