public import CmuxiOSFeatureKit
import CmuxMobileTunnel
public import Foundation

/// One machine's tunnel for the in-app browser: a per-launch token, and one
/// `LoopbackProxy` per remote port, started on first use and stopped with
/// the route. The browser's data store for the route carries the token cookie.
public actor WebRoute {
    public nonisolated let id: WebRouteID
    public nonisolated let cookie: WebTunnelCookie
    private let dialer: any TunnelDialer
    private var proxies: [UInt16: LoopbackProxy] = [:]
    private var socksServer: SocksProxyServer?
    private var socksEndpoint: WebSocksEndpoint?

    public init(id: WebRouteID, dialer: any TunnelDialer, cookie: WebTunnelCookie = .random()) {
        self.id = id
        self.dialer = dialer
        self.cookie = cookie
    }

    /// The phone URL for `path` on the machine's `localhost:<port>`.
    public func url(remotePort: UInt16, path: String = "/", query: String? = nil) async throws -> URL {
        let proxy: LoopbackProxy
        if let existing = proxies[remotePort] {
            proxy = existing
        } else {
            proxy = LoopbackProxy(remotePort: remotePort, token: cookie.value, dialer: dialer)
            proxies[remotePort] = proxy
        }
        do {
            try await proxy.start()
        } catch {
            proxies[remotePort] = nil
            throw error
        }
        guard let url = await proxy.url(path: path, query: query) else { throw LoopbackProxyError.cannotListen }
        return url
    }

    /// The remote port a phone loopback port stands for, when this route owns it.
    public func remotePort(forLocalPort port: UInt16) async -> UInt16? {
        for (remote, proxy) in proxies where await proxy.localPort == port { return remote }
        return nil
    }

    /// Starts the generic, credentialed SOCKS5 route for this machine.
    ///
    /// The route's own tunnel handles loopback destinations. A non-loopback
    /// destination is denied unless `direct` is explicitly supplied, keeping
    /// Mac/SSH browser routes default-deny while permitting a direct-address
    /// composition to opt into `DirectConnectBackend` or WireGuard.
    ///
    /// This listener is a companion route for clients that can configure a
    /// SOCKS proxy. WKWebView still uses the per-port HTTP loopback proxies
    /// above because WebKit bypasses SOCKS for localhost destinations.
    public func startSocks(direct: (any SocksConnectBackend)? = nil, port: Int = 0) async throws -> WebSocksEndpoint {
        if let socksEndpoint, socksServer?.isListening == true { return socksEndpoint }
        if let stale = socksServer { await stale.stop() }
        let credential = SocksCredential.random()
        let backend = MobileTunnelSocksBackend(tunnel: dialer, direct: direct)
        let server = try await SocksProxyServer.start(backend: backend, port: port, credential: credential)
        let endpoint = WebSocksEndpoint(port: UInt16(server.port), username: credential.username,
                                        password: credential.password)
        socksServer = server
        socksEndpoint = endpoint
        return endpoint
    }

    /// The current generic SOCKS endpoint, if one was started.
    public func currentSocksEndpoint() -> WebSocksEndpoint? {
        guard socksServer?.isListening == true else { return nil }
        return socksEndpoint
    }

    public func stop() async {
        if let socksServer { await socksServer.stop() }
        socksServer = nil
        socksEndpoint = nil
        for proxy in proxies.values { await proxy.stop() }
        proxies.removeAll()
    }
}
