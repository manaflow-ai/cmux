import Foundation

/// Per-host settings that belong to this device, not to the synced record.
public struct SSHHostSettings: Hashable, Sendable, Codable {
    public var auth: SSHHostAuth

    public init(auth: SSHHostAuth = .unset) {
        self.auth = auth
    }
}
