#if os(iOS)
import QuickLook
import SwiftUI

/// Hosts the system Quick Look document preview for one local artifact file.
struct ChatArtifactQuickLookView: UIViewControllerRepresentable {
    let fileURL: URL
    let title: String

    func makeCoordinator() -> ChatArtifactQuickLookCoordinator {
        ChatArtifactQuickLookCoordinator(
            item: ChatArtifactQuickLookItem(fileURL: fileURL, title: title)
        )
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.update(
            item: ChatArtifactQuickLookItem(fileURL: fileURL, title: title)
        )
        controller.reloadData()
    }
}
#endif
