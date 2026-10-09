public import CmuxiOSFeatureKit
public import CmuxMobileLink
import CmuxMobileWire

/// Opens `tcp.forward` channels on the phone's one `MobileLinkClient` per
/// Mac (c14-web.md section 3). The Mac re-checks every port.
public struct LinkTunnelDialer: TunnelDialer {
    public let client: MobileLinkClient

    public init(client: MobileLinkClient) {
        self.client = client
    }

    public func dial(port: UInt16) async throws -> any TunnelStream {
        let request = MobileChannelRequest(kind: .tcpForward, channelClass: .bulk, window: 1 << 20,
                                           params: ["port": .int(Int64(port))], stream: "tcp.forward/\(port)",
                                           priority: .bulk)
        do {
            let opened = try await client.open(request)
            return LinkTunnelStream(channel: opened.channel)
        } catch MobileLinkClientError.refused(let code, _, let retryable) {
            throw TunnelDialError.refused(code: code, retryable: retryable)
        } catch {
            throw TunnelDialError.offline
        }
    }
}
