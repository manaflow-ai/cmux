public import CmuxiOSFeatureKit
import Foundation

/// No sync: hosts stay on this device until lane B1 lands.
public struct DisabledHostsSync: HostsSyncChannel {
    public init() {}
    public func publish(_ hosts: [HostRecord], revision: UInt64) async {}
}
