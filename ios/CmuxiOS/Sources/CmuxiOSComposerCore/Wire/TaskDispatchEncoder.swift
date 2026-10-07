public import CmuxiOSFeatureKit
public import CmuxMobileWire
public import CmuxiOSWorkspacesCore
import Foundation

/// Builds the `task.dispatch` op (a0-rpc.md 5.9) for a draft. The intent key
/// is the idempotency key; the prompt goes as a plain string value.
public struct TaskDispatchEncoder: Sendable {
    public var draft: TaskDraft
    public var key: IntentKey

    public init(draft: TaskDraft, key: IntentKey) {
        self.draft = draft
        self.key = key
    }

    public var frame: OpFrame {
        var params: [String: JSONValue] = [
            "host": .string(draft.hostID.rawValue),
            "agent": .string(draft.agentID),
            "prompt": .string(draft.prompt),
        ]
        if let workspace = draft.workspaceID { params["workspace"] = .string(workspace) }
        if let model = draft.model { params["model"] = .string(model) }
        if let effort = draft.effort { params["effort"] = .string(effort) }
        if !draft.uploads.isEmpty { params["attachments"] = .array(draft.uploads.map { .string($0) }) }
        if let template = draft.templateID { params["template"] = .string(template) }
        return OpFrame(op: "task.dispatch", params: .object(params), idempotencyKey: key.rawValue, origin: .user,
                       stream: "task:" + draft.hostID.rawValue)
    }

    /// The receipt for the owner's answer.
    public func receipt(for outcome: WorkspaceOpOutcome) -> TaskReceipt {
        switch outcome {
        case .applied(let result):
            let workspace = result.value["workspace"]?.stringValue ?? draft.workspaceID ?? ""
            return .started(key: key, workspaceID: workspace, taskID: result.value["task"]?.stringValue,
                            tabID: result.value["tab"]?.stringValue)
        case .rejected(let reject):
            return .refused(key: key, reason: reject.message)
        }
    }
}
