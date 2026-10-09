import CmuxiOSFeatureKit
import CmuxiOSWebCore

/// One machine the tunnel browser reaches, as the screens need it.
struct WebTarget: Sendable {
    let id: WebRouteID
    let name: String
    let dialer: @Sendable () async throws -> any TunnelDialer
    /// Advertised ports (Mac); nil when the machine has no list (SSH).
    let ports: (@Sendable () async throws -> [WebPort])?
    /// Runs when the route's last screen closed.
    let onStop: @Sendable () async -> Void

    var host: HostID {
        switch id {
        case .mac(let host), .ssh(let host): host
        }
    }
}
