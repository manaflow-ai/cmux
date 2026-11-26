#if os(iOS)
import QuickLook

/// Retains and supplies the current artifact item to a Quick Look controller.
@MainActor
final class ChatArtifactQuickLookCoordinator: NSObject, QLPreviewControllerDataSource {
    private(set) var item: ChatArtifactQuickLookItem

    init(item: ChatArtifactQuickLookItem) {
        self.item = item
    }

    func update(item: ChatArtifactQuickLookItem) {
        self.item = item
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> any QLPreviewItem {
        item
    }
}
#endif
