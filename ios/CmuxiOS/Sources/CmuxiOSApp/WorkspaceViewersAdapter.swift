import CmuxiOSViewers
import CmuxiOSViewersCore
import CmuxiOSWorkspaces
import UIKit

/// Connects C5's workspace detail to C13's screens without either feature
/// module importing the other.
@MainActor
final class WorkspaceViewersAdapter: WorkspaceViewerOpening {
    private let feature: ViewersFeature

    init(feature: ViewersFeature) {
        self.feature = feature
    }

    func changesScreen(for target: WorkspaceViewerTarget) -> UIViewController {
        feature.makeChanges(for: viewerTarget(target))
    }

    func filesScreen(for target: WorkspaceViewerTarget) -> UIViewController {
        feature.makeFiles(for: viewerTarget(target))
    }

    func todoScreen(for target: WorkspaceViewerTarget) -> UIViewController {
        feature.makeTodo(for: viewerTarget(target))
    }

    private func viewerTarget(_ target: WorkspaceViewerTarget) -> ViewerTarget {
        ViewerTarget(hostID: target.hostID, hostName: target.hostName, workspaceID: target.workspaceID, title: target.title)
    }
}
