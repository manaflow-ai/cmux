public import CmuxiOSFeatureKit

/// One host's choices in the picker.
public struct WorkspacePickerSection: Identifiable, Hashable, Sendable {
    public var id: HostID { host.hostID }
    public var host: HostWorkspaces
    public var choices: [WorkspacePickerChoice]
}
