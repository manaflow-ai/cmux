public import CmuxControlPlane
import CmuxMobileWire
public import Foundation

/// The real `WorkspaceChannelFactory` (lane B1): one `ControlPlaneClient`
/// per host on `/v1/wire/host/<host>`, authenticated as this install.
public struct ControlPlaneWorkspaceChannelFactory: WorkspaceChannelFactory {
    let apiBaseURL: URL
    let appVersion: String
    let reasons: ControlPlaneChannelReasons
    let transport: any ControlPlaneTransport
    let reconnect: ReconnectPolicy
    let install: @Sendable () async throws -> String
    let token: @Sendable () async throws -> String

    /// `install` resolves this device's install id for `hello`; `token`
    /// mints its bearer (both from `InstallIdentity`).
    public init(apiBaseURL: URL, appVersion: String, reasons: ControlPlaneChannelReasons,
                transport: any ControlPlaneTransport = URLSessionControlPlaneTransport(),
                reconnect: ReconnectPolicy = ReconnectPolicy(),
                install: @escaping @Sendable () async throws -> String,
                token: @escaping @Sendable () async throws -> String) {
        self.apiBaseURL = apiBaseURL
        self.appVersion = appVersion
        self.reasons = reasons
        self.transport = transport
        self.reconnect = reconnect
        self.install = install
        self.token = token
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
        return ControlPlaneWorkspaceChannel(hostID: host.id, reasons: reasons) {
            let client = HelloClient(install: try await install(), platform: "ios", appVersion: appVersion)
            let configuration = ControlPlaneConfiguration(url: url, client: client, reconnect: reconnect)
            return ControlPlaneClient(configuration: configuration, transport: transport, tokenProvider: token)
        }
    }
}
