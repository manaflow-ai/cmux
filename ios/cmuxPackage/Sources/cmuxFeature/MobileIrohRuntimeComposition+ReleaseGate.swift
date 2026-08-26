#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import Foundation

public extension MobileIrohRuntimeComposition {
    /// Supplies local-only continuity evidence to the Iroh release gate.
    func releaseGateEndpointIdentity() async -> CmxIrohPeerIdentity? {
        await runtime?.snapshot().endpointID
    }

    /// Supplies the non-secret installed relay expiry to the release gate.
    func releaseGateRelayCredentialExpiry() async -> Date? {
        await runtime?.relayCredentialExpiresAt()
    }
}
#endif
