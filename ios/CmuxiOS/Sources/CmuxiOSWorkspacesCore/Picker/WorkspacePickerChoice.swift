public import CmuxiOSFeatureKit

/// One row of the workspace picker.
public struct WorkspacePickerChoice: Identifiable, Hashable, Sendable {
    public var id: String
    public var selection: WorkspaceSelection
    /// The workspace title, or nil for "New Workspace".
    public var title: String?
    public var hostName: String
    public var status: WorkspaceStatus?
    public var isEnabled: Bool
}
