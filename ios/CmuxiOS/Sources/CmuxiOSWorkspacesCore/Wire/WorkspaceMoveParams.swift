import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// `workspace.move` params: `group` absent keeps the group, `null` ungroups.
struct WorkspaceMoveParams: Sendable {
    var workspace: String
    var group: WorkspaceGroupPlacement
    var index: Int

    var json: JSONValue {
        var object: [String: JSONValue] = ["workspace": .string(workspace), "index": .int(Int64(max(0, index)))]
        switch group {
        case .keep: break
        case .ungrouped: object["group"] = .null
        case .group(let id): object["group"] = .string(id)
        }
        return .object(object)
    }
}
