import CmuxiOSFiles
import CmuxiOSViewersCore
import CmuxMobileWire
import UIKit

/// Lane C13's entry point (c13-viewers.md): the changes screen and the
/// file browser of a workspace, and `router`, the `FileViewerHook` that
/// replaces C4's QuickLook default. The composition root makes one per
/// signed-in shell over the account's `ViewerContentSource`.
@MainActor
public final class ViewersFeature {
    public let source: any ViewerContentSource
    public let router: ViewerRouter

    public init(source: any ViewerContentSource) {
        self.source = source
        router = ViewerRouter(source: source)
    }

    /// The workspace's git changes; push it on the presenter's navigation controller.
    public func makeChanges(for target: ViewerTarget) -> UIViewController {
        let model = ChangesModel(target: target, source: source)
        let router = router
        weak var screen: ChangesViewController?
        let controller = ChangesViewController(model: model) { [weak model] file in
            guard let model, let path = model.absolutePath(of: file), let navigation = screen?.navigationController else { return }
            navigation.pushViewController(router.viewer(host: target.hostID, path: path, size: nil), animated: true)
        }
        screen = controller
        controller.hidesBottomBarWhenPushed = true
        return controller
    }

    /// The workspace's folder on the Mac.
    public func makeFiles(for target: ViewerTarget) -> UIViewController {
        let controller = FileBrowserViewController(model: FileBrowserModel(target: target, source: source), router: router)
        controller.hidesBottomBarWhenPushed = true
        return controller
    }
}
