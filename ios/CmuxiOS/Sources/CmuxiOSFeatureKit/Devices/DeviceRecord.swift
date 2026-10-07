public import Foundation

/// One device of the account.
public struct DeviceRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: DevicePlatform
    public var trust: DeviceTrust
    public var isThisDevice: Bool
    public var lastSeen: Date?

    public init(
        id: String, name: String, platform: DevicePlatform, trust: DeviceTrust,
        isThisDevice: Bool = false, lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.trust = trust
        self.isThisDevice = isThisDevice
        self.lastSeen = lastSeen
    }
}
