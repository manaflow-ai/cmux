public import CmuxiOSFeatureKit
public import CmuxRemoteDesktop

/// Opens remote desktop streams to a paired Mac. The real one rides the
/// Mac's `cmux.mobile/1` session (`LinkRemoteDesktopConnector`); with no
/// carrier the open fails with `linkLost` and the screen says so.
@MainActor
public protocol RemoteDesktopConnector: AnyObject {
    func makeClient(host: HostID, params: RemoteDesktopChannelParams) -> RemoteDesktopClient?
}
