import Foundation

/// Whether the phone can use a Mac, and which side to update.
public enum MacCompatibility: Hashable, Sendable {
    case compatible
    /// The Mac speaks an older protocol than this app (or the account's
    /// floor) needs.
    case macUpdateRequired(minimumProtocol: Int)
    /// The Mac is newer than this app understands.
    case phoneUpdateRequired(macProtocol: Int)
    /// The protocol matches but the Mac lacks capabilities the app needs.
    case missingCapabilities([String])

    public var isCompatible: Bool { self == .compatible }
}
