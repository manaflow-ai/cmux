public import CmuxiOSFeatureKit
import Foundation

/// The cross-device sync seam for host records (lane B1). The store
/// publishes each committed revision; B1 applies records from the account's
/// other devices through `LocalHostsStore.applyRemote`. Only records cross
/// it; device settings and secrets never do.
public protocol HostsSyncChannel: Sendable {
    func publish(_ hosts: [HostRecord], revision: UInt64) async
}
