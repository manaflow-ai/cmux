import CmuxiOSFeatureKit
import CmuxiOSFiles
import CmuxiOSViewersCore
import UIKit

/// Lane C13's `FileViewerHook` (replaces C4's QuickLook default): text and
/// code, Markdown, images and PDFs open in the viewers, everything else in
/// QuickLook. Also opens files still on the Mac (download first).
@MainActor
public final class ViewerRouter: FileViewerHook {
    let source: any ViewerContentSource

    public init(source: any ViewerContentSource) {
        self.source = source
    }

    /// A downloaded file (C4's transfer list): presented in its own navigation controller.
    public func present(_ file: LocalFile, from presenter: UIViewController) {
        let viewer = FileViewerContainer(name: file.name, mime: file.mime, content: .local(file.url))
        let navigation = UINavigationController(rootViewController: viewer)
        viewer.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
        presenter.present(navigation, animated: true)
    }

    /// A file on the Mac: pushed at once, downloaded through C4, then shown.
    func viewer(host: HostID, path: String, size: UInt64?) -> UIViewController {
        let name = (path as NSString).lastPathComponent
        let source = source
        return FileViewerContainer(name: name, content: .remote {
            try await source.fetch(host: host, path: path, size: size)
        })
    }
}
