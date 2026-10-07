import Foundation

/// A user intent on the team's machines, sent to `CloudDO` as one op with
/// the caller's idempotency key. Pause covers "stop" and "hibernate": the
/// provider keeps memory and disk, there is no separate stop.
public enum CloudIntent: Hashable, Sendable {
    case create(name: String?, size: CloudMachineSize)
    case start(machine: String)
    case pause(machine: String)
    case delete(machine: String)
    case rename(machine: String, name: String)

    /// The `cmux.wire/1` op name.
    public var op: String {
        switch self {
        case .create: "cloud.machine.create"
        case .start: "cloud.machine.start"
        case .pause: "cloud.machine.pause"
        case .delete: "cloud.machine.delete"
        case .rename: "cloud.machine.rename"
        }
    }

    /// The machine the intent targets; nil for a create.
    public var machine: String? {
        switch self {
        case .create: nil
        case .start(let id), .pause(let id), .delete(let id), .rename(let id, _): id
        }
    }
}
