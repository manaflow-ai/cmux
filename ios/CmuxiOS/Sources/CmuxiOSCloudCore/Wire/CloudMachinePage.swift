public import CmuxiOSFeatureKit

/// One page of `cloud.machine.list`.
public struct CloudMachinePage: Hashable, Sendable {
    public var machines: [CloudMachine]
    public var nextCursor: String?
    /// The team registry revision when the page was read.
    public var revision: UInt64

    public init(machines: [CloudMachine], nextCursor: String?, revision: UInt64) {
        self.machines = machines
        self.nextCursor = nextCursor
        self.revision = revision
    }
}
