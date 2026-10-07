import CmuxiOSFeatureKit
import CmuxMobileLink

/// Host id -> the phone's one `MobileLinkClient` for that Mac, the same
/// client terminals use (D1 owns one per Mac, with B2/B4 carriers and B6's
/// signer). Until it is wired the files seam stays on its mock.
public protocol FileHostConnector: Sendable {
    func client(for host: HostID) async throws -> MobileLinkClient
}
