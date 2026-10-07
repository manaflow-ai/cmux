import CmuxMobileWire
import Foundation

/// What the phone needs from `host:<host>` (HostDO's own stream,
/// b1-control-do.md section 4): the Mac's presence and its negotiated caps.
struct HostPresenceMirror: Sendable {
    /// `online | offline | sleeping | paused`; nil before the snapshot.
    private(set) var presence: String?
    private(set) var caps: Set<String> = []

    mutating func apply(snapshot: SnapshotFrame) {
        presence = snapshot.state["presence"]?.stringValue
        caps = Self.caps(in: snapshot.state["caps"])
    }

    mutating func apply(event: EventFrame) {
        switch event.op {
        case "host.presence.set":
            if let value = event.params["presence"]?.stringValue { presence = value }
        case "host.caps.set":
            caps = Self.caps(in: event.params)
        default:
            break
        }
    }

    private static func caps(in value: JSONValue?) -> Set<String> {
        guard case .array(let items)? = value?["caps"] else { return [] }
        return Set(items.compactMap(\.stringValue))
    }
}
