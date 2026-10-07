public import CmuxiOSBrowser
public import CmuxiOSBrowserCore
public import CmuxiOSFeatureKit
import CmuxiOSWebCore
public import UIKit

/// Lane C14's entry (c14-web.md): the dev-server list of a Mac (ports plus
/// booted simulators) and the WKWebView browser over a Mac's `tcp.forward`
/// tunnel or an SSH host's `direct-tcpip`. The composition root makes one.
@MainActor
public final class WebFeature {
    /// The phone's one `MobileLinkClient` per Mac (D1); nil leaves Mac routes offline.
    let clients: (any MobileLinkClientProvider)?
    /// C2's screen over `LinkSimulatorStreamSource`; nil hides simulators.
    let simulators: BrowserFeature?
    let routes = WebRoutes()

    public init(clients: (any MobileLinkClientProvider)?, simulators: BrowserFeature?) {
        self.clients = clients
        self.simulators = simulators
    }

    /// Dev servers and simulators of a paired Mac.
    public func makeMacScreen(host: HostID, name: String) -> UIViewController {
        let clients = clients
        let target = WebTarget(id: .mac(host), name: name, dialer: {
            guard let clients else { throw TunnelDialError.offline }
            return LinkTunnelDialer(client: try await clients.client(for: host))
        }, ports: {
            guard let clients else { throw TunnelDialError.offline }
            return try await LinkWebPortSource(client: try await clients.client(for: host)).ports()
        }, onStop: {})
        return WebPortsViewController(feature: self, target: target)
    }

    /// The browser for an SSH host's localhost through `opener` (C9's chain).
    public func makeSSHScreen(host: HostID, name: String, opener: any SSHDirectTCPIPOpener) -> UIViewController {
        let target = WebTarget(id: .ssh(host), name: name, dialer: { SSHTunnelDialer(opener: opener) }, ports: nil,
                               onStop: { await opener.close() })
        return WebPortsViewController(feature: self, target: target)
    }
}
