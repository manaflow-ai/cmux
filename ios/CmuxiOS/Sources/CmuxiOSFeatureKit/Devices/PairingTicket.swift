public import Foundation

/// An opaque pairing ticket from a QR code or same-account discovery.
/// Lane B6 owns its encoding; the shell only carries it.
public struct PairingTicket: Hashable, Sendable {
    public var payload: Data

    public init(payload: Data) { self.payload = payload }
}
