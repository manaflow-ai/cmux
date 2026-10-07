public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// The phone's confirmed copy of one Mac's `task:<host>` stream: written only
/// by the owner's snapshots and `task.state.set` events. A seq gap or an
/// epoch change asks for a snapshot; duplicates are ignored.
public struct TaskStreamMirror: Hashable, Sendable {
    public enum Applied: Hashable, Sendable {
        case changed
        case unchanged
        /// Not applied: the caller requests a snapshot.
        case needsSnapshot
    }

    public let hostID: HostID
    public private(set) var seq: UInt64?
    public private(set) var epoch: String?
    public private(set) var agents: [ComposerAgent] = []
    public private(set) var tasks: [TaskRecord] = []
    /// True between a gap and the snapshot that repairs it.
    public private(set) var isResyncing = false

    public init(hostID: HostID) {
        self.hostID = hostID
    }

    public mutating func apply(snapshot: SnapshotFrame) -> Applied {
        guard let state = try? snapshot.state.decode(as: WireTaskStreamState.self) else {
            isResyncing = true
            return .needsSnapshot
        }
        seq = snapshot.seq
        epoch = snapshot.epoch
        agents = state.agents.map(\.composerAgent)
        // The stream is one Mac's: its records belong to this host whatever id form they carry.
        tasks = state.tasks.map { task in
            var record = task.record
            record.hostID = hostID
            return record
        }
        isResyncing = false
        return .changed
    }

    public mutating func apply(event: EventFrame) -> Applied {
        guard let seq, !isResyncing else { return .needsSnapshot }
        if let epoch, let other = event.epoch, other != epoch {
            isResyncing = true
            return .needsSnapshot
        }
        if event.seq <= seq { return .unchanged }
        guard event.seq == seq + 1 else {
            isResyncing = true
            return .needsSnapshot
        }
        self.seq = event.seq
        guard event.op == "task.state.set", let params = try? event.params.decode(as: TaskStateParams.self) else {
            return .unchanged
        }
        guard let index = tasks.firstIndex(where: { $0.id == params.task }) else {
            // A state for a task this mirror never saw: the snapshot is stale.
            isResyncing = true
            return .needsSnapshot
        }
        tasks[index].state = params.state
        if let tab = params.tab { tasks[index].tabID = tab }
        return .changed
    }
}
