public import CmuxMobileWire
import Foundation

/// The frames of `cloud:<team>` the phone acts on.
public enum CloudWireFrame: Hashable, Sendable {
    /// The head at `seq`; machine rows come from a list read.
    case snapshot(seq: UInt64)
    /// A commit at `seq`. `change` is nil for commits that changed no
    /// machine (ledger-only) and for replayed log events.
    case event(seq: UInt64, change: CloudWireChange?)
    case error(code: String)
    case ignored

    public static func decode(_ data: Data, decoder: CloudWireDecoder = CloudWireDecoder()) -> CloudWireFrame {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let type = json["t"]?.stringValue else {
            return .ignored
        }
        switch type {
        case "snapshot":
            guard let seq = Self.seq(json["seq"]) else { return .ignored }
            return .snapshot(seq: seq)
        case "event":
            guard let seq = Self.seq(json["seq"]) else { return .ignored }
            return .event(seq: seq, change: Self.change(json, decoder: decoder))
        case "error":
            return .error(code: json["code"]?.stringValue ?? "unknown")
        default:
            return .ignored
        }
    }

    private static func change(_ json: JSONValue, decoder: CloudWireDecoder) -> CloudWireChange? {
        guard let name = json["event"]?.stringValue, let data = json["data"] else { return nil }
        switch name {
        case "cloud.machine.upsert":
            guard let value = data["machine"], let machine = try? decoder.machine(value) else { return .unreadable }
            return .upsert(machine)
        case "cloud.machine.removed":
            guard let id = data["machine"]?.stringValue else { return .unreadable }
            return .removed(machine: id, revision: CloudWireDecoder.revision(data["revision"]?.stringValue))
        default:
            return .other
        }
    }

    private static func seq(_ value: JSONValue?) -> UInt64? {
        switch value {
        case .int(let n)? where n >= 0: UInt64(n)
        case .double(let d)? where d >= 0: UInt64(d)
        case .string(let s)?: UInt64(s)
        default: nil
        }
    }
}
