public import CmuxControlPlane
import CmuxMobileWire
public import Foundation

/// The real `WorkspaceChannelFactory` (lane B1): a session on each host's
/// `/v1/wire/host/<host>` socket, authenticated as this install. With a
/// `HostSocketPool` the session is a lease on the Mac's one shared socket
/// (workspaces, tasks, presence and signaling ride it together); without one
/// each channel owns a client.
public struct ControlPlaneWorkspaceChannelFactory: WorkspaceChannelFactory {
    let apiBaseURL: URL
    let appVersion: String
    let reasons: ControlPlaneChannelReasons
    let transport: any ControlPlaneTransport
    let reconnect: ReconnectPolicy
    let install: @Sendable () async throws -> String
    let token: @Sendable () async throws -> String
    /// The Mac-owned stream each channel subscribes (`workspace` or `task`).
    public var streamKind = "workspace"
    /// The account's shared host sockets (D1b); nil: one client per channel.
    public var sessions: HostSocketPool?

    /// `install` resolves this device's install id for `hello`; `token`
    /// mints its bearer (both from `InstallIdentity`).
    public init(apiBaseURL: URL, appVersion: String, reasons: ControlPlaneChannelReasons,
                transport: any ControlPlaneTransport = URLSessionControlPlaneTransport(),
                reconnect: ReconnectPolicy = ReconnectPolicy(),
                sessions: HostSocketPool? = nil,
                install: @escaping @Sendable () async throws -> String,
                token: @escaping @Sendable () async throws -> String) {
        self.sessions = sessions
        self.apiBaseURL = apiBaseURL
        self.appVersion = appVersion
        self.reasons = reasons
        self.transport = transport
        self.reconnect = reconnect
        self.install = install
        self.token = token
    }

    /// The same sockets for another Mac-owned stream (C8: `task`).
    public func streaming(_ kind: String) -> ControlPlaneWorkspaceChannelFactory {
        var copy = self
        copy.streamKind = kind
        return copy
    }

    /// `wss://<api>/v1/wire/host/<host>` (`ws` for a plain-http dev origin).
    public func socketURL(for host: WorkspaceHostDescriptor) -> URL {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let id = host.id.rawValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? host.id.rawValue
        components.path = "/v1/wire/host/" + id
        components.query = nil
        return components.url ?? apiBaseURL
    }

    public func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel {
        let url = socketURL(for: host)
        let appVersion = self.appVersion
        let transport = self.transport
        let reconnect = self.reconnect
        let install = self.install
        let token = self.token
        if let sessions {
            let id = host.id.rawValue
            return ControlPlaneWorkspaceChannel(hostID: host.id, reasons: reasons, streamKind: streamKind) {
                await sessions.session(host: id)
            }
        }
        return ControlPlaneWorkspaceChannel(hostID: host.id, reasons: reasons, streamKind: streamKind) {
            let client = HelloClient(install: try await install(), platform: "ios", appVersion: appVersion)
            let configuration = ControlPlaneConfiguration(url: url, client: client, reconnect: reconnect)
            return ControlPlaneClient(configuration: configuration, transport: transport, tokenProvider: token)
        }
    }
}
