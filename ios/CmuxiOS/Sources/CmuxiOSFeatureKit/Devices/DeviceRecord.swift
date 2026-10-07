public import Foundation

/// One device of the account.
public struct DeviceRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var trust: DeviceTrust
    public var isThisDevice: Bool
    public var lastSeen: Date?
    /// A Mac's host id (`host_…`), the id its workspaces, control socket and
    /// link use; nil when the record id already is that id (mocks) or the
    /// device is no host.
    public var hostID: String?

    public init(
        id: String, name: String, platform: DevicePlatform, trust: DeviceTrust,
        isThisDevice: Bool = false, lastSeen: Date? = nil, hostID: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.platform = platform
        self.trust = trust
        self.isThisDevice = isThisDevice
        self.lastSeen = lastSeen
    }
}
