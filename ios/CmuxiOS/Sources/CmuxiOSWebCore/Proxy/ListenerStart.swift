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
        let ready: Bool = await withCheckedContinuation { continuation in
            gate.install(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(true)
                case .failed, .waiting, .cancelled: gate.finish(false)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard ready else {
            listener.cancel()
            throw LoopbackProxyError.cannotListen
        }
        listener.stateUpdateHandler = nil
        return listener
    }
}
