import CmuxMobileLink
import CmuxMobileWire

/// `tunnel.ports` from a Mac over its `MobileLinkClient`.
public struct LinkWebPortSource: WebPortSource {
    public let client: MobileLinkClient

    public init(client: MobileLinkClient) {
        self.client = client
    }

    public func ports() async throws -> [WebPort] {
        let value = try await client.read("tunnel.ports", params: .object([:]))
        return try value.decode(as: TunnelPortsResult.self).ports.map {
            WebPort(port: $0.port, source: $0.source == .detected ? .detected : .allowed, workspace: $0.workspace, process: $0.process)
        }
    }
}
