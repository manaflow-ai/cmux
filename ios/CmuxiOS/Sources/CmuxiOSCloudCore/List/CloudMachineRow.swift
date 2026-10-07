public import CmuxiOSFeatureKit
import Foundation

/// One row: a machine, or a create the owner has not answered.
public struct CloudMachineRow: Identifiable, Hashable, Sendable {
    /// The machine id, or `create:<key>` for a pending create.
    public var id: String
    public var title: String
    public var size: CloudMachineSize
    /// nil for a pending create.
    public var status: CloudMachineStatus?
    public var pauseReason: CloudPauseReason?
    public var isClassic: Bool
    public var failureMessage: String?
    public var actions: [CloudMachineAction]

    public init(id: String, title: String, size: CloudMachineSize, status: CloudMachineStatus?,
                pauseReason: CloudPauseReason? = nil, isClassic: Bool = false, failureMessage: String? = nil,
                actions: [CloudMachineAction] = []) {
        self.id = id
        self.title = title
        self.size = size
        self.status = status
        self.pauseReason = pauseReason
        self.isClassic = isClassic
        self.failureMessage = failureMessage
        self.actions = actions
    }

    public var isPendingCreate: Bool { status == nil }
}
