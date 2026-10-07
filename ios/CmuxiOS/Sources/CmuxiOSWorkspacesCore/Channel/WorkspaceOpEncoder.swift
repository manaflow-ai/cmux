public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// Turns an intent into the family op for one host's stream.
public struct WorkspaceOpEncoder: Sendable {
    public let hostID: HostID

    public init(hostID: HostID) { self.hostID = hostID }

    public var stream: String { "workspace:" + hostID.rawValue }

    public func frame(for intent: WorkspaceIntent, key: IntentKey) throws -> OpFrame {
        let (op, params): (String, JSONValue)
        switch intent {
        case .create(_, let title):
            op = "workspace.create"
            params = try JSONValue(encoding: WorkspaceCreateParams(host: hostID.rawValue, name: title))
        case .rename(let id, let title):
            op = "workspace.rename"
            params = try JSONValue(encoding: WorkspaceRenameParams(workspace: id, name: title))
        case .close(let id):
            op = "workspace.close"
            params = try JSONValue(encoding: WorkspaceRefParams(workspace: id))
        case .markRead(let id):
            op = "workspace.read"
            params = try JSONValue(encoding: WorkspaceRefParams(workspace: id))
        case .move(let id, let group, let index):
            op = "workspace.move"
            params = WorkspaceMoveParams(workspace: id, group: group, index: index).json
        case .renameGroup(_, let group, let name):
            op = "workspace.group.rename"
            params = try JSONValue(encoding: WorkspaceGroupRenameParams(group: group, name: name))
        case .customize(let id, let color, let icon):
            op = "workspace.customize"
            params = WorkspaceCustomizeParams(workspace: id, color: color, icon: icon).json
        }
        return OpFrame(op: op, params: params, idempotencyKey: key.rawValue, origin: .user, stream: stream)
    }
}
