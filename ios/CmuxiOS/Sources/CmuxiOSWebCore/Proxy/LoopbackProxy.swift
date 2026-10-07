public import CmuxiOSFeatureKit
public import Foundation
@preconcurrency import Network

/// A listener on the phone's `127.0.0.1` (and `::1`) for one remote port of
/// one route (c14-web.md section 4). It binds the same port number as the
/// remote first, so the page origin is unchanged; when that port is taken it
/// binds any free port and rewrites `Host` to the remote port. Every
/// connection must present the route's token cookie.
public actor LoopbackProxy {
    public nonisolated let remotePort: UInt16
    private let token: String
    private let dialer: any TunnelDialer
    private let queue = DispatchQueue(label: "dev.cmux.ios.web.proxy")
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: LoopbackConnectionStream] = [:]
    private var stopped = false
    public private(set) var localPort: UInt16 = 0

    public init(remotePort: UInt16, token: String, dialer: any TunnelDialer) {
        self.remotePort = remotePort
        self.token = token
        self.dialer = dialer
    }

    /// Whether the phone port equals the remote port (no Host rewrite).
    public var mirrors: Bool { localPort == remotePort }

    /// The page URL for `path` through this proxy.
    public func url(path: String = "/", query: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(localPort)
        components.path = path.hasPrefix("/") ? path : "/" + path
        components.percentEncodedQuery = query
        return components.url
    }

    /// Starts listening (idempotent) and returns the phone port.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard !stopped else { throw LoopbackProxyError.stopped }
        if localPort != 0 { return localPort }
        let accept: @Sendable (NWConnection) -> Void = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let ipv4: NWListener
        if let mirror = NWEndpoint.Port(rawValue: remotePort),
           let bound = try? await ListenerStart(host: .ipv4(.loopback), port: mirror).start(queue: queue, accept: accept) {
            ipv4 = bound
        } else {
            ipv4 = try await ListenerStart(host: .ipv4(.loopback), port: .any).start(queue: queue, accept: accept)
        }
        guard !stopped, let port = ipv4.port else {
            ipv4.cancel()
            throw LoopbackProxyError.stopped
        }
        listeners = [ipv4]
        localPort = port.rawValue
        // `localhost` may resolve to ::1 first; best effort on the same port.
        if let ipv6 = try? await ListenerStart(host: .ipv6(.loopback), port: port).start(queue: queue, accept: accept) {
            if stopped { ipv6.cancel() } else { listeners.append(ipv6) }
        }
        return localPort
    }

    /// Stops listening and ends every open connection.
    public func stop() {
        stopped = true
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let stream = LoopbackConnectionStream(connection: connection)
        let key = ObjectIdentifier(stream)
        connections[key] = stream
        let handler = ProxyConnection(local: stream, token: token, remotePort: remotePort, localPort: localPort, dialer: dialer)
        Task { [weak self] in
            await handler.run()
            await self?.forget(key)
        }
    }

    private func forget(_ key: ObjectIdentifier) {
        connections[key] = nil
    }
}
