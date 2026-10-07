import QuickLook
import UIKit

/// The default `FileViewerHook`: QuickLook over the local file.
@MainActor
public final class QuickLookFileViewer: NSObject, FileViewerHook, QLPreviewControllerDataSource {
    private var current: URL?

    override public init() {
        super.init()
    }

    public func present(_ file: LocalFile, from presenter: UIViewController) {
        current = file.url
        let preview = QLPreviewController()
        preview.dataSource = self
        presenter.present(preview, animated: true)
    }

    public nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    public nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (current ?? URL(fileURLWithPath: "/dev/null")) as NSURL }
    }
}
