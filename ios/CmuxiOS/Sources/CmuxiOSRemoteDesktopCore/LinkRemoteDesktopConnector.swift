public import CmuxiOSBrowserCore
public import CmuxiOSFeatureKit
import CmuxRemoteDesktop

/// `RemoteDesktopConnector` over each Mac's one `MobileLinkClient`, through
/// the `MobileLinkClientProvider` seam C2 (browser) and C4 (files) use, so
/// every feature shares one session per Mac.
@MainActor
public final class LinkRemoteDesktopConnector: RemoteDesktopConnector {
    private let clients: any MobileLinkClientProvider

    public init(clients: any MobileLinkClientProvider) {
        self.clients = clients
    }

    public func makeClient(host: HostID, params: RemoteDesktopChannelParams) -> RemoteDesktopClient? {
        RemoteDesktopClient(opener: ProvidedLinkOpener(clients: clients, host: host), params: params)
    }
}
