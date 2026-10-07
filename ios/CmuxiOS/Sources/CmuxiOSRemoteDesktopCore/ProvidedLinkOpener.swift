public import CmuxiOSBrowserCore
public import CmuxiOSFeatureKit
public import CmuxMobileLink
public import CmuxRemoteDesktop

/// Opens `rd` channels on the Mac's `MobileLinkClient`, asked from the
/// provider at open time (no carrier: the open fails `linkLost`).
public struct ProvidedLinkOpener: RemoteDesktopChannelOpener {
    public let clients: any MobileLinkClientProvider
    public let host: HostID

    public init(clients: any MobileLinkClientProvider, host: HostID) {
        self.clients = clients
        self.host = host
    }

    public func openChannel(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel {
        try await clients.client(for: host).open(request)
    }

    public func openDatagramLane(pairedWith channel: MobileOpenedChannel) async throws -> MobileDatagramLane {
        try await clients.client(for: host).openDatagramLane(for: channel)
    }
}
