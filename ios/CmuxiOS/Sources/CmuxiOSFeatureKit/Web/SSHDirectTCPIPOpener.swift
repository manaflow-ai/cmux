/// Opens SSH `direct-tcpip` channels on an established connection chain
/// (lane C9 owns the connection; C14's SSH dialer uses this seam).
public protocol SSHDirectTCPIPOpener: Sendable {
    /// A byte stream to `host:port` as seen from the SSH server.
    func openDirectTCPIP(host: String, port: Int) async throws -> any TunnelStream
    /// Closes the connection chain.
    func close() async
}
