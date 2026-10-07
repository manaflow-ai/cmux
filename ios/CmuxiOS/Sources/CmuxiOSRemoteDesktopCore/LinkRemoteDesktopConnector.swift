public import CmuxiOSFeatureKit
public import CmuxMobileLink
public import CmuxRemoteDesktop

/// `RemoteDesktopConnector` over each Mac's `MobileLinkClient` (the same
/// session C1's terminals use). `client(for:)` is the app's link directory;
/// nil means no carrier reaches that Mac.
@MainActor
public final class LinkRemoteDesktopConnector: RemoteDesktopConnector {
    private let client: @MainActor (HostID) -> MobileLinkClient?

    public init(client: @escaping @MainActor (HostID) -> MobileLinkClient?) {
        self.client = client
    }

    public func makeClient(host: HostID, params: RemoteDesktopChannelParams) -> RemoteDesktopClient? {
        guard let link = client(host) else { return nil }
        return RemoteDesktopClient(opener: link, params: params)
    }
}
