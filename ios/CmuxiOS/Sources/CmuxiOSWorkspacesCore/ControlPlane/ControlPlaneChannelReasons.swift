import Foundation

/// The offline reasons a control-plane channel shows, localized by the
/// caller (the core has no string catalog).
public struct ControlPlaneChannelReasons: Sendable {
    public var macOffline: String
    public var macSleeping: String
    public var macPaused: String
    public var signedOut: String
    public var refused: String

    public init(macOffline: String, macSleeping: String, macPaused: String, signedOut: String, refused: String) {
        self.macOffline = macOffline
        self.macSleeping = macSleeping
        self.macPaused = macPaused
        self.signedOut = signedOut
        self.refused = refused
    }
}
