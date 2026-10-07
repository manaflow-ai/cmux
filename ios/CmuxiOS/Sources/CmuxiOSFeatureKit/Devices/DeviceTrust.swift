import Foundation

/// Pairing state of a device as the owner records it.
public enum DeviceTrust: String, Hashable, Sendable, CaseIterable {
    /// Same account, discovered, not yet paired.
    case discovered
    case trusted
    case revoked
}
