import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import CmuxiOSTerminalLink
import CmuxMobileLink

/// The one `MobileLinkClient` per Mac, from the account's link directory,
/// for every feature that needs it: files (C4), the browser stream (C2) and
/// workspace terminals (C1, through `LinkWorkspaceTerminalSourceFactory`).
struct LinkClientProvider: FileHostConnector, MobileLinkClientProvider {
    let directory: AccountLinkDirectory

    func client(for host: HostID) async throws -> MobileLinkClient {
        guard let client = await directory.client(for: host) else { throw MobileLinkClientError.linkLost }
        return client
    }
}
