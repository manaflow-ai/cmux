public import CmuxiOSFeatureKit

/// Per-Mac capabilities (B5 serves them from A0 negotiation).
public protocol MacCapabilitiesSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[HostID: MacCapabilities]>>
}
