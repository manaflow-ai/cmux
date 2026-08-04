import CmuxIrohTransport
import Foundation

enum MobileIrohTestEndpointError: Error {
    case unavailable
}

/// Minimal healthy endpoint shared by runtime-composition test fixtures.
actor MobileIrohTestEndpoint: CmxIrohEndpoint {
    private let peerIdentity: CmxIrohPeerIdentity

    init(identity: CmxIrohPeerIdentity) {
        peerIdentity = identity
    }

    func identity() -> CmxIrohPeerIdentity { peerIdentity }

    func address() -> CmxIrohEndpointAddress {
        CmxIrohEndpointAddress(identity: peerIdentity, pathHints: [])
    }

    func connect(
        to _: CmxIrohEndpointAddress,
        alpn _: Data
    ) throws -> any CmxIrohConnection {
        throw MobileIrohTestEndpointError.unavailable
    }

    func accept() -> (any CmxIrohConnection)? { nil }
    func replaceRelays(_: [CmxIrohRelayConfiguration]) {}

    func healthEvents() -> AsyncStream<CmxIrohEndpointHealthEvent> {
        AsyncStream { $0.finish() }
    }

    func isHealthy() -> Bool { true }
    func close() {}
}
