import Foundation

/// The system prompts onboarding primes.
public enum PermissionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case notifications
    case localNetwork
    case camera
}
