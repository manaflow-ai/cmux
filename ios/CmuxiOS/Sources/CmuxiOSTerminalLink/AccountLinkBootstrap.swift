public import CmuxMobileConnect
public import CmuxPairing

/// What the account's link directory needs once sign-in resolved the
/// install (built by the app from B6's runtime and the install identity).
public struct AccountLinkBootstrap: Sendable {
    public var credentials: MobileDeviceCredentials
    /// The account's `trust:<user>` mirror (shared with the device registry).
    public var mirror: TrustStoreMirror
    public var lookup: any TrustedKeyLookup
    public var options: MobileConnectOptions
    /// One Mac's HostDO signaling relay (B1), made when its client is.
    public var signaling: MobileLinkRegistry.SignalingFactory

    public init(credentials: MobileDeviceCredentials, mirror: TrustStoreMirror, lookup: any TrustedKeyLookup,
                options: MobileConnectOptions, signaling: @escaping MobileLinkRegistry.SignalingFactory) {
        self.credentials = credentials
        self.mirror = mirror
        self.lookup = lookup
        self.options = options
        self.signaling = signaling
    }
}
