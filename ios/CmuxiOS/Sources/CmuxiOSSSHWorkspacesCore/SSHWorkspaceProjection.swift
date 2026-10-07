public import CmuxiOSSSHCore
public import CmuxMobileWire
import Foundation

/// Discovery as `workspace:<host>` state, so an SSH host rides the same
/// mirror as a Mac: a session is a workspace (grouped by tool), a tmux
/// window or the session itself is a terminal tab whose id names its
/// catalog target.
public struct SSHWorkspaceProjection: Sendable {
    public let hostID: String

    public init(hostID: String) { self.hostID = hostID }

    public func state(_ sessions: [SSHDiscoveredSession]) -> JSONValue {
        let kinds = SSHDiscoveredSession.Kind.allOrdered.filter { kind in sessions.contains { $0.kind == kind } }
        let groups: [JSONValue] = kinds.enumerated().map { index, kind in
            .object(["id": .string(Self.groupID(kind)), "name": .string(kind.rawValue), "order": .int(Int64(index))])
        }
        let workspaces: [JSONValue] = sessions.enumerated().map { order, session in
            let tabs: [JSONValue]
            if session.windows.isEmpty {
                tabs = [Self.tab(id: session.target.surfaceID, title: session.name.rawValue)]
            } else {
                tabs = session.windows.map { Self.tab(id: $0.target.surfaceID, title: "\($0.index): \($0.name)") }
            }
            var workspace: [String: JSONValue] = [
                "id": .string(session.id), "name": .string(session.name.rawValue), "order": .int(Int64(order)),
                "group": .object(["id": .string(Self.groupID(session.kind)), "name": .string(session.kind.rawValue),
                                  "order": .int(Int64(kinds.firstIndex(of: session.kind) ?? 0))]),
                "panes": .array([.object(["id": .string("pane:" + session.id), "tabs": .array(tabs)])]),
            ]
            if let activity = session.activity, activity > 0 { workspace["activity_at"] = .int(activity * 1000) }
            return .object(workspace)
        }
        return .object(["host": .string(hostID), "workspaces": .array(workspaces), "groups": .array(groups)])
    }

    static func groupID(_ kind: SSHDiscoveredSession.Kind) -> String { "ssh-" + kind.rawValue }

    private static func tab(id: String, title: String) -> JSONValue {
        .object(["id": .string(id), "kind": .string("terminal"), "title": .string(title), "terminal": .string(id),
                 "status": .string("idle")])
    }
}

extension SSHDiscoveredSession.Kind {
    static let allOrdered: [SSHDiscoveredSession.Kind] = [.tmux, .screen, .cmuxTUI]
}
