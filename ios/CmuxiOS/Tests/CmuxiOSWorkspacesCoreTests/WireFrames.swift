import CmuxMobileWire
import Foundation

/// Builders for `workspace:<host>` frames in tests.
struct WireFrames {
    let host: String
    var stream: String { "workspace:" + host }

    static func tab(_ id: String, kind: String = "terminal", title: String = "zsh", status: String? = nil,
                    unread: Int? = nil, preview: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "title": .string(title)]
        if kind == "terminal" { o["terminal"] = .string("term_" + id.dropFirst(4)) }
        if let status { o["status"] = .string(status) }
        if let unread { o["unread"] = .int(Int64(unread)) }
        if let preview { o["preview"] = .string(preview) }
        return .object(o)
    }

    static func workspace(_ id: String, name: String, order: Int, pinned: Bool = false,
                          group: (String, String)? = nil, activity: Int64? = nil,
                          panes: [(String, [JSONValue])]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "order": .int(Int64(order)), "pinned": .bool(pinned),
            "panes": .array(panes.map { .object(["id": .string($0.0), "tabs": .array($0.1)]) }),
        ]
        if let group { o["group"] = .object(["id": .string(group.0), "name": .string(group.1)]) }
        if let activity { o["activity_at"] = .int(activity) }
        return .object(o)
    }

    func snapshot(seq: UInt64, _ workspaces: [JSONValue], decided: [DecidedKey] = []) -> SnapshotFrame {
        SnapshotFrame(stream: stream, seq: seq,
                      state: .object(["host": .string(host), "workspaces": .array(workspaces)]), decided: decided)
    }

    func event(seq: UInt64, _ op: String, _ params: [String: JSONValue]) -> EventFrame {
        EventFrame(stream: stream, seq: seq, tx: "tx_\(seq)", op: op, params: .object(params),
                   actor: ["identity": .string("host:" + host)], origin: .remote, at: 1_791_331_200_000)
    }

    /// One workspace with one terminal tab.
    static func simple(_ id: String, name: String, order: Int, status: String? = nil, unread: Int? = nil) -> JSONValue {
        workspace(id, name: name, order: order, panes: [("pane_" + id.dropFirst(3), [
            tab("tab_" + id.dropFirst(3), status: status, unread: unread),
        ])])
    }
}
