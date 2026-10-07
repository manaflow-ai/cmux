import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// `workspace.customize` params: absent leaves a field, `null` clears it.
struct WorkspaceCustomizeParams: Sendable {
    var workspace: String
    var color: WorkspaceLookChange
    var icon: WorkspaceLookChange

    var json: JSONValue {
        var object: [String: JSONValue] = ["workspace": .string(workspace)]
        Self.put(color, "color", into: &object)
        Self.put(icon, "icon", into: &object)
        return .object(object)
    }

    private static func put(_ change: WorkspaceLookChange, _ key: String, into object: inout [String: JSONValue]) {
        switch change {
        case .unchanged: break
        case .clear: object[key] = .null
        case .set(let value): object[key] = .string(value)
        }
    }
}
