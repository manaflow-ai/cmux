public import CmuxiOSFeatureKit

/// Tunnel streams through an SSH connection chain (c14-web.md section 5):
/// `direct-tcpip` to `127.0.0.1:<port>` on the last hop. The SSH user has a
/// shell there already, so any port is allowed; the host is always loopback.
public struct SSHTunnelDialer: TunnelDialer {
    public static let targetHost = "127.0.0.1"

    public let opener: any SSHDirectTCPIPOpener

    public init(opener: any SSHDirectTCPIPOpener) {
        self.opener = opener
    }

    public func dial(port: UInt16) async throws -> any TunnelStream {
        guard port > 0 else { throw TunnelDialError.refused(code: "tunnel.port_not_allowed", retryable: false) }
        do {
            return try await opener.openDirectTCPIP(host: Self.targetHost, port: Int(port))
        } catch let error as TunnelDialError {
            throw error
        } catch {
            throw TunnelDialError.refused(code: "tunnel.connect_refused", retryable: true)
        }
    }
}
