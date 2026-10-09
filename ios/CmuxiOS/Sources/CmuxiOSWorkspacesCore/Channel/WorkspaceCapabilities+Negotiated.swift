public import CmuxiOSFeatureKit

extension WorkspaceCapabilities {
    /// The changes a host accepts given the negotiated caps. Create and
    /// rename are in the base family; close, read and preview are cap-gated
    /// (c5-workspaces.md section 2), move, group rename and customize too (E3).
    public init(negotiated caps: Set<String>) {
        var made: WorkspaceCapabilities = [.create, .rename]
        if caps.contains("workspace.close") { made.insert(.close) }
        if caps.contains("workspace.read") { made.insert(.markRead) }
        if caps.contains("workspace.preview") { made.insert(.preview) }
        if caps.contains("workspace.move") { made.insert(.move) }
        if caps.contains("workspace.group.rename") { made.insert(.renameGroup) }
        if caps.contains("workspace.customize") { made.insert(.customize) }
        self = made
    }
}
