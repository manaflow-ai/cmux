import Foundation

/// One Cloud machine of the team, as `CloudDO` publishes it
/// (`CloudMachine` in backend/packages/protocol cloud-machine-ops.ts).
public struct CloudMachine: Identifiable, Hashable, Sendable {
    /// `vm_…`.
    public var id: String
    public var creator: String
    public var name: String?
    public var size: CloudMachineSize
    public var status: CloudMachineStatus
    public var daemonVersion: String?
    /// The overlay host id (`host_…`); nil until the machine is bound.
    public var host: HostID?
    /// Imported from cmux Cloud classic and not upgraded yet.
    public var isClassic: Bool
    public var createdAt: Date
    public var lastActiveAt: Date?
    public var idleSeconds: Int
    public var failure: CloudMachineFailure?
    public var pauseReason: CloudPauseReason?
    /// The owner's stream sequence of this record's last change.
    public var revision: UInt64

    public init(
        id: String, creator: String = "", name: String? = nil, size: CloudMachineSize = CloudMachineSize(),
        status: CloudMachineStatus, daemonVersion: String? = nil, host: HostID? = nil, isClassic: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 0), lastActiveAt: Date? = nil, idleSeconds: Int = 0,
        failure: CloudMachineFailure? = nil, pauseReason: CloudPauseReason? = nil, revision: UInt64 = 0
    ) {
        self.id = id
        self.creator = creator
        self.name = name
        self.size = size
        self.status = status
        self.daemonVersion = daemonVersion
        self.host = host
        self.isClassic = isClassic
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.idleSeconds = idleSeconds
        self.failure = failure
        self.pauseReason = pauseReason
        self.revision = revision
    }

    /// The name, or the id when the machine has none.
    public var displayName: String { name ?? id }
}
