import CmuxiOSFeatureKit
import CmuxiOSFiles
import CmuxiOSSFTPCore
import CmuxiOSSSH
import CmuxiOSViewers
import CmuxiOSViewersCore
import UIKit

/// Lane E5 (e5-extras.md section 1): SSH hosts' files over SFTP. One
/// session directory, transfer owner, transfer list and viewer set per
/// process, account-independent like the SSH device state, so it works
/// signed out too.
@MainActor
final class SFTPComposition {
    let directory = SFTPHostDirectory()
    private(set) lazy var transfer = SFTPFileTransfer(directory: directory)
    private(set) lazy var files = FilesFeature(transfer: transfer)
    private(set) lazy var viewers: ViewersFeature = {
        let made = ViewersFeature(source: SFTPViewerContentSource(directory: directory, transfer: transfer))
        let files = files
        made.router.fileActions = ViewerFileActions(
            upload: { host, folder, presenter, anchor in
                files.pickAndSend(to: .directory(folder), host: host, from: presenter, anchor: anchor)
            },
            transfers: { _ in files.makeTransferList(host: nil) })
        files.viewer = made.router
        return made
    }()

    /// The Hosts tab's Files action: registers the host's opener, shows its
    /// login folder, and releases the session when the screen goes away.
    var screens: SSHFileScreens {
        SSHFileScreens { [unowned self] host, name, opener in
            let directory = directory
            let lease = await directory.register(opener, for: host)
            let target = ViewerTarget(hostID: host, hostName: name, workspaceID: SFTPViewerContentSource.rootID, title: name)
            return viewers.makeFiles(for: target) {
                Task { await directory.release(host, lease: lease) }
            }
        }
    }
}
