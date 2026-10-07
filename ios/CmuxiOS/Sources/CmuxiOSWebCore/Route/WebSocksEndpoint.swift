/// Credentials and loopback port for a route's generic SOCKS5 listener.
///
/// The credentials are returned to the owning browser surface only. They are
/// per route launch and are invalid after `WebRoute.stop()`.
public struct WebSocksEndpoint: Hashable, Sendable {
    public let port: UInt16
    public let username: String
    public let password: String

    public init(port: UInt16, username: String, password: String) {
        self.port = port
        self.username = username
        self.password = password
    }
}
