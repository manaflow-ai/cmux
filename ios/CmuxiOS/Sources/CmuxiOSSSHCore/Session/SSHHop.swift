public import CmuxiOSFeatureKit
public import CmuxMobileSSH
import Foundation

/// One host of a connection chain: where it is and who it is.
public struct SSHHop: Hashable, Sendable {
    public var hostID: HostID
    public var name: String
    public var endpoint: SSHEndpoint

    public init(hostID: HostID, name: String, endpoint: SSHEndpoint) {
        self.hostID = hostID
        self.name = name
        self.endpoint = endpoint
    }
}
