public import CmuxiOSFeatureKit
public import CmuxMobileLink

/// Host id -> the phone's one `MobileLinkClient` for that Mac: the same
/// client terminals (C1) and files (C4, `FileHostConnector` has this shape)
/// use, so D1 hands every feature one session per Mac.
public protocol MobileLinkClientProvider: Sendable {
    func client(for host: HostID) async throws -> MobileLinkClient
}
