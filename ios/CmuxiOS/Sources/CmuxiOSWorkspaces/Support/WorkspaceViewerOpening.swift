public import CmuxiOSFeatureKit
public import UIKit

/// The workspace a viewer opens for.
public struct WorkspaceViewerTarget: Hashable, Sendable {
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

/// Seam for lane C13 (viewers): the workspace detail shows "Changes" and
/// "Files" rows when one is set, and pushes the screens it returns. The
/// composition root adapts C13's `ViewersFeature`.
@MainActor
public protocol WorkspaceViewerOpening: AnyObject {
    func changesScreen(for target: WorkspaceViewerTarget) -> UIViewController
    func filesScreen(for target: WorkspaceViewerTarget) -> UIViewController
}
