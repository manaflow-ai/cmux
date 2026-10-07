public import CmuxiOSFeatureKit

extension WorkspaceCapabilities {
    /// The changes a host accepts given the negotiated caps. Create and
    /// rename are in the base family; close, read and preview are cap-gated
    /// (c5-workspaces.md section 2).
    public init(negotiated caps: Set<String>) {
        var made: WorkspaceCapabilities = [.create, .rename]
        if caps.contains("workspace.close") { made.insert(.close) }
        if caps.contains("workspace.read") { made.insert(.markRead) }
        if caps.contains("workspace.preview") { made.insert(.preview) }
        self = made
    }
}
