import Foundation

/// The phone's own pairing attempt, which the registry snapshot confirms.
public enum PairingIntent: Hashable, Sendable {
    case idle
    case pairing(PairingCandidate)
    /// A QR ticket was redeemed; the owner named the Mac.
    case paired(name: String)
    case failed(message: String)
}
