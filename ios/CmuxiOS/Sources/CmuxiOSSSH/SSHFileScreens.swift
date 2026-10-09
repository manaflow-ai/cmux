public import CmuxiOSFeatureKit
public import CmuxiOSSFTPCore
public import UIKit

/// Lane E5's files screen for an SSH host, injected so the Hosts tab can
/// open it without importing the viewers or files features. The screen owns
/// the opener's session while it is on screen.
@MainActor
public struct SSHFileScreens {
    public var open: @MainActor (HostID, String, any SFTPSessionOpening) async -> UIViewController

    public init(open: @escaping @MainActor (HostID, String, any SFTPSessionOpening) async -> UIViewController) {
        self.open = open
    }
}
