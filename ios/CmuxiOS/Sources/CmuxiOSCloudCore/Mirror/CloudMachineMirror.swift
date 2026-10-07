public import CmuxiOSFeatureKit

/// The confirmed machines, written only from owner data (list reads, live
/// events, op results). Every record carries its revision, so an older copy
/// never replaces a newer one, and a removal leaves a tombstone so a list
/// read taken before it cannot bring the machine back.
public struct CloudMachineMirror: Hashable, Sendable {
    public private(set) var machines: [String: CloudMachine] = [:]
    private var tombstones: [String: UInt64] = [:]
    public private(set) var isLoaded = false

    public init() {}

    /// Takes a complete list read at `revision` (the team registry revision).
    /// Records newer than the list survive; a machine missing from the list
    /// stays only when it changed after the list was read.
    public mutating func replace(with list: [CloudMachine], at revision: UInt64) {
        var next: [String: CloudMachine] = [:]
        for machine in list {
            if let tomb = tombstones[machine.id], tomb >= machine.revision { continue }
            if let mine = machines[machine.id], mine.revision > machine.revision {
                next[machine.id] = mine
            } else {
                next[machine.id] = machine
            }
        }
        for (id, mine) in machines where next[id] == nil && mine.revision > revision {
            next[id] = mine
        }
        machines = next
        tombstones = tombstones.filter { $0.value > revision }
        isLoaded = true
    }

    /// Applies an owner record; returns false when it was older.
    @discardableResult
    public mutating func upsert(_ machine: CloudMachine) -> Bool {
        if let tomb = tombstones[machine.id], tomb >= machine.revision { return false }
        if let mine = machines[machine.id], mine.revision > machine.revision { return false }
        machines[machine.id] = machine
        return true
    }

    public mutating func remove(_ id: String, at revision: UInt64) {
        if let mine = machines[id], mine.revision > revision { return }
        machines[id] = nil
        tombstones[id] = max(tombstones[id] ?? 0, revision)
    }

    /// Oldest first (creation order), the order the list shows.
    public var sorted: [CloudMachine] {
        machines.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}
