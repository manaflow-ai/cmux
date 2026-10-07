public import CmuxiOSFeatureKit
public import Foundation

/// One machine's tunnel for the in-app browser: a per-launch token, and one
/// `LoopbackProxy` per remote port, started on first use and stopped with
/// the route. The browser's data store for the route carries the token cookie.
public actor WebRoute {
    public nonisolated let id: WebRouteID
    public nonisolated let cookie: WebTunnelCookie
    private let dialer: any TunnelDialer
    private var proxies: [UInt16: LoopbackProxy] = [:]

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

    public func stop() async {
        for proxy in proxies.values { await proxy.stop() }
        proxies.removeAll()
    }
}
