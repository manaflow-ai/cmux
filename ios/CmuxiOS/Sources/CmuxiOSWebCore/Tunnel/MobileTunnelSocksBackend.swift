import CmuxMobileTunnel
import CmuxiOSFeatureKit
import Foundation

/// Adapts the cmux-next browser's narrow `TunnelDialer` to the generic
/// `CmuxMobileTunnel` SOCKS backend.
///
/// Loopback destinations always use the route's authenticated machine tunnel.
/// Non-loopback destinations are refused unless the caller explicitly supplies
/// a direct backend (for example `DirectConnectBackend` or a host-specific
/// WireGuard backend). This keeps the C14 Mac/SSH loopback policy default-deny
/// while leaving direct-address routing an explicit composition choice.
public struct MobileTunnelSocksBackend: SocksConnectBackend {
    public let tunnel: any TunnelDialer
    public let direct: (any SocksConnectBackend)?

    public init(tunnel: any TunnelDialer, direct: (any SocksConnectBackend)? = nil) {
        self.tunnel = tunnel
        self.direct = direct
    }

    public func open(host: String, port: Int) async throws -> any TunnelByteStream {
        guard port > 0, port <= Int(UInt16.max), let remotePort = UInt16(exactly: port) else {
            throw TunnelOpenError.notAllowed
        }
        if host.isTunnelLoopbackHost {
            do {
                return TunnelStreamByteAdapter(stream: try await tunnel.dial(port: remotePort))
            } catch let error as TunnelDialError {
                throw Self.openError(error)
            } catch {
                throw TunnelOpenError.unavailable
            }
        }
        guard let direct else { throw TunnelOpenError.notAllowed }
        return try await direct.open(host: host, port: port)
    }

    private static func openError(_ error: TunnelDialError) -> TunnelOpenError {
        switch error {
        case .offline:
            return .unavailable
        case .refused(let code, let retryable):
            switch code {
            case "tunnel.port_not_allowed", "auth.revoked": return .notAllowed
            case "tunnel.connect_refused": return .connectionRefused
            case "tunnel.host_unreachable": return .hostUnreachable
            case "tunnel.network_unreachable": return .networkUnreachable
            case "tunnel.timed_out": return .timedOut
            default: return retryable ? .unavailable : .generalFailure
            }
        }
    }
}

/// Bridges the C14 FeatureKit stream to CmuxMobileTunnel's pull-based byte
/// stream. The relay's one-read/one-write discipline is preserved on both
/// sides; no buffering is introduced here.
private actor TunnelStreamByteAdapter: TunnelByteStream {
    private let stream: any CmuxiOSFeatureKit.TunnelStream

    init(stream: any CmuxiOSFeatureKit.TunnelStream) {
        self.stream = stream
    }

    func read() async throws -> Data? {
        try await stream.read()
    }

    func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    func finishWriting() async {
        await stream.finishWriting()
    }

    func close() async {
        await stream.close()
    }
}
