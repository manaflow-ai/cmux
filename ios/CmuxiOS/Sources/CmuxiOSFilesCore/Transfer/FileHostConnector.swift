import CmuxiOSFeatureKit
import CmuxMobileFiles

/// Host id -> a started `cmux.mobile/1` client session for that Mac. Filled
/// by the lane that dials Macs from the app (B2/B4 carriers with D1's
/// per-host `CmuxLink` owner and B6's signer); until then the files seam
/// stays on its mock.
public protocol FileHostConnector: Sendable {
    func session(for host: HostID) async throws -> MobileClientSession
}
