public import CmuxiOSFeatureKit
public import UIKit

/// Lane C14's browser screens, injected so the Hosts tab can open a host's
/// localhost without importing the web module: a paired Mac's dev servers,
/// and an SSH host's localhost through a `direct-tcpip` opener.
@MainActor
public struct SSHBrowserScreens {
    public var mac: (HostID, String) -> UIViewController
    /// Opens a direct-address host through its authenticated link route.
    ///
    /// This remains a separate seam from `mac` even while both currently
    /// render the tunnel browser: paired Macs are discovered by account
    /// pairing, while direct hosts come from B4's saved endpoint directory.
    public var direct: (HostID, String) -> UIViewController
    public var ssh: (HostID, String, any SSHDirectTCPIPOpener) -> UIViewController

    public init(mac: @escaping (HostID, String) -> UIViewController,
                direct: ((HostID, String) -> UIViewController)? = nil,
                ssh: @escaping (HostID, String, any SSHDirectTCPIPOpener) -> UIViewController) {
        self.mac = mac
        self.direct = direct ?? mac
        self.ssh = ssh
    }
}
