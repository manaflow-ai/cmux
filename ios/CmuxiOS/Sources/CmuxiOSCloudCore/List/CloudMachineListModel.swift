public import CmuxiOSFeatureKit
import Foundation

/// The Cloud tab's content from one snapshot. Pure: no I/O, no clock.
public struct CloudMachineListModel: Hashable, Sendable {
    public var sections: [CloudMachineSection]
    public var usage: CloudUsageSummary?
    public var isLoaded: Bool
    public var isLive: Bool

    public init(snapshot: SourceSnapshot<CloudState>) {
        let state = snapshot.value
        isLive = snapshot.connection.isLive
        isLoaded = state.isLoaded
        usage = state.plan.map(CloudUsageSummary.init(plan:))
        var active: [CloudMachineRow] = state.creating.map { pending in
            CloudMachineRow(id: "create:\(pending.id.rawValue)", title: pending.name ?? "", size: pending.size, status: nil)
        }
        var paused: [CloudMachineRow] = []
        var failed: [CloudMachineRow] = []
        for machine in state.machines {
            let row = Self.row(machine, live: isLive)
            switch machine.status {
            case .paused: paused.append(row)
            case .failed: failed.append(row)
            case .provisioning, .starting, .running, .pausing, .deleting: active.append(row)
            }
        }
        sections = [
            CloudMachineSection(kind: .active, rows: active),
            CloudMachineSection(kind: .paused, rows: paused),
            CloudMachineSection(kind: .failed, rows: failed),
        ].filter { !$0.rows.isEmpty }
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// Actions follow the owner's state; none while offline (nothing queues)
    /// or while a transition is in flight, except delete.
    public static func actions(for machine: CloudMachine, live: Bool) -> [CloudMachineAction] {
        guard live else { return [] }
        switch machine.status {
        case .running: return [.pause, .delete]
        case .paused: return [.resume, .delete]
        case .failed, .provisioning, .starting, .pausing: return [.delete]
        case .deleting: return []
        }
    }

    private static func row(_ machine: CloudMachine, live: Bool) -> CloudMachineRow {
        CloudMachineRow(id: machine.id, title: machine.displayName, size: machine.size, status: machine.status,
                        pauseReason: machine.status == .paused ? machine.pauseReason : nil, isClassic: machine.isClassic,
                        failureMessage: machine.status == .failed ? machine.failure?.message : nil,
                        actions: actions(for: machine, live: live))
    }
}
