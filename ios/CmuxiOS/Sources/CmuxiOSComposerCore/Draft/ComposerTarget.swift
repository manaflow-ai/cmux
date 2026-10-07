public import CmuxiOSFeatureKit
import Foundation

/// Where a task goes: a Mac and one of its workspaces, or a new workspace
/// there (`workspaceID == nil`). Client view state.
public struct ComposerTarget: Hashable, Sendable, Codable {
    public var hostID: HostID
    public var workspaceID: WorkspaceSummary.ID?

    public init(hostID: HostID, workspaceID: WorkspaceSummary.ID? = nil) {
        self.hostID = hostID
        self.workspaceID = workspaceID
    }

    public init(_ selection: WorkspaceSelection) {
        self.init(hostID: selection.hostID, workspaceID: selection.workspaceID)
    }

    /// The draft store's key: one draft per target.
    public var storageKey: String { hostID.rawValue + "|" + (workspaceID ?? "new") }
}
