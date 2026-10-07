import CmuxiOSFeatureKit

/// The workspace a viewer was opened from.
public struct ViewerTarget: Hashable, Sendable {
    public var hostID: HostID
    public var hostName: String
    public var workspaceID: String
    public var title: String

    public init(hostID: HostID, hostName: String, workspaceID: String, title: String) {
        self.hostID = hostID
        self.hostName = hostName
        self.workspaceID = workspaceID
        self.title = title
    }
}
