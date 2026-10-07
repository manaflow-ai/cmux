import Foundation
@preconcurrency import Network

/// Binds an `NWListener` to one loopback address and port and waits for it
/// to be ready (or to fail, for example with the port in use).
struct ListenerStart {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port

    func start(queue: DispatchQueue, accept: @escaping @Sendable (NWConnection) -> Void) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = accept
        let gate = StartGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: Task { await gate.finish(true) }
            case .failed, .waiting, .cancelled: Task { await gate.finish(false) }
            default: break
            }
        }
        // carve-out: Network.framework delivers callbacks on a queue it is given.
        listener.start(queue: queue)
        let ready = await gate.wait()
        guard ready else {
            listener.cancel()
            throw LoopbackProxyError.cannotListen
        }
        listener.stateUpdateHandler = nil
        return listener
    }
}
