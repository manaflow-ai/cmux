public import CmuxiOSFeatureKit
public import UIKit

/// Upload and the transfer list for a browsable host, injected by the
/// composition root so viewers never import the files feature (lane E5:
/// SSH hosts over SFTP). Nil hides both.
@MainActor
public struct ViewerFileActions {
    /// Picks files and uploads them into `folder` on `host`.
    public var upload: (_ host: HostID, _ folder: String, _ presenter: UIViewController, _ anchor: UIBarButtonItem?) -> Void
    /// The host's transfer list, pushed or presented by the caller.
    public var transfers: (_ host: HostID) -> UIViewController

    public init(upload: @escaping (HostID, String, UIViewController, UIBarButtonItem?) -> Void,
                transfers: @escaping (HostID) -> UIViewController) {
        self.upload = upload
        self.transfers = transfers
    }
}
