public import CmuxiOSFeatureKit
public import UIKit

/// Lane C14's browser screens, injected so the Hosts tab can open a host's
/// localhost without importing the web module: a paired Mac's dev servers,
/// and an SSH host's localhost through a `direct-tcpip` opener.
@MainActor
public struct SSHBrowserScreens {
    public var mac: (HostID, String) -> UIViewController
    public var ssh: (HostID, String, any SSHDirectTCPIPOpener) -> UIViewController

    public init(mac: @escaping (HostID, String) -> UIViewController,
                ssh: @escaping (HostID, String, any SSHDirectTCPIPOpener) -> UIViewController) {
        self.mac = mac
        self.ssh = ssh
    }
}
