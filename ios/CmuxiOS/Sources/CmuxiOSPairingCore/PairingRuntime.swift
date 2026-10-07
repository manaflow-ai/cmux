public import CmuxPairing

/// Everything the registry needs once the account is known.
public struct PairingRuntime: Sendable {
    public var account: PairingAccount
    public var mirror: TrustStoreMirror
    public var ops: any PairingOps
    public var presence: any HostPresenceSource
    /// Closes the owner sockets when the registry goes away (sign-out, account switch).
    public var stop: @Sendable () async -> Void

    public init(account: PairingAccount, mirror: TrustStoreMirror, ops: any PairingOps, presence: any HostPresenceSource,
                stop: @escaping @Sendable () async -> Void = {}) {
        self.account = account
        self.mirror = mirror
        self.ops = ops
        self.presence = presence
        self.stop = stop
    }
}
