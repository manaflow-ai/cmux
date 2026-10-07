import CmuxiOSFeatureKit
import Foundation

/// A Mac on the account that this phone can pair with.
public struct PairingCandidate: Identifiable, Hashable, Sendable {
    public var id: DeviceRecord.ID
    public var name: String

    public init(id: DeviceRecord.ID, name: String) {
        self.id = id
        self.name = name
    }
}
