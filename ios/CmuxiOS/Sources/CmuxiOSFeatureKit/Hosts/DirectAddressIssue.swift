import Foundation

/// What is wrong with a direct address the user typed.
public enum DirectAddressIssue: Hashable, Sendable, CaseIterable {
    case addressMissing
    /// Spaces, a scheme (`https://`) or a path.
    case addressInvalid
    /// `host:port` in the address field; the port has its own field.
    case addressHasPort
    case portInvalid
    case hostKeyMissing
    /// Not base64 of a 32-byte key.
    case hostKeyInvalid
}
