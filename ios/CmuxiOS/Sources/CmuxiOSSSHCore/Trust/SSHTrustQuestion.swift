public import CmuxMobileSSH
import Foundation

/// What the user is asked about a server identity key.
public enum SSHTrustQuestion: Hashable, Sendable {
    /// First connection: nothing is pinned for `identity`.
    case unknown(hostName: String, identity: String, presented: SSHHostKey)
    /// A different key is pinned: a reinstalled server or an impersonation.
    case changed(hostName: String, identity: String, pinned: SSHHostKey, presented: SSHHostKey)

    public var presented: SSHHostKey {
        switch self {
        case .unknown(_, _, let key), .changed(_, _, _, let key): key
        }
    }
}
