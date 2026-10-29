#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import Foundation

public extension MobileIrxRuntimeComposition {
    func releaseGateEndpointIdentity() async -> CmxIrohPeerIdentity? {
        guard let identity else { return nil }
        return try? CmxIrohPeerIdentity(endpointID: identity.endpointIDHex)
    }
    func releaseGateRelayCredentialExpiry() async -> Date? {
        cache?.relayCredentials.map { Date(timeIntervalSince1970: Double($0.expiresAt)) }.min()
    }
}
#endif
