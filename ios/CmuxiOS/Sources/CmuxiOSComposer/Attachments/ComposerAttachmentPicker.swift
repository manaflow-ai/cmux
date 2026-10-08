import CmuxiOSFiles
import CmuxiOSFilesCore
import UIKit

/// Adapts C4's native pickers for the task composer.
///
/// `FilePickerCoordinator` stages provider URLs into app-owned files and uses
/// the same `FileStager` as `FileSendCoordinator`. Composer never retains a
/// PhotosUI or document-provider URL, which keeps the upload lifetime valid
/// after the picker has been dismissed and makes cancellation cleanup shared
/// with terminal and inbox uploads.
@MainActor
final class ComposerAttachmentPicker {
    /// A staged file ready to hand to C4's upload coordinator.
    struct Picked: Sendable {
        let url: URL
        let name: String
        let mime: String
        let byteCount: Int64

        init(_ file: StagedFile) {
            url = file.url
            name = file.name
            mime = file.mime
            byteCount = file.byteCount
        }
    }

    var onPicked: ((Picked) -> Void)?
    private let coordinator: FilePickerCoordinator
    private typealias Present = @MainActor (UIViewController, @escaping FilePickerCoordinator.Completion) -> Void

    /// Uses a standalone C4 stager for injected upload seams (tests and
    /// previews). The real app passes `FilesFeature.picker`, which shares its
    /// stager with `FileSendCoordinator`.
    init(coordinator: FilePickerCoordinator = FilePickerCoordinator()) {
        self.coordinator = coordinator
    }

    func presentPhotos(from presenter: UIViewController) {
        present(using: coordinator.presentPhotos, from: presenter)
    }

    func presentCamera(from presenter: UIViewController) {
        present(using: coordinator.presentCamera, from: presenter)
    }

    func presentFiles(from presenter: UIViewController) {
        present(using: coordinator.presentDocuments, from: presenter)
    }

    func discard(_ picked: Picked) {
        coordinator.discard(StagedFile(url: picked.url, name: picked.name, mime: picked.mime,
                                       byteCount: picked.byteCount))
    }

    private func present(using present: @escaping Present,
                         from presenter: UIViewController) {
        present(presenter) { [weak self, coordinator] files in
            guard let self else {
                files.forEach { coordinator.discard($0) }
                return
            }
            emit(files)
        }
    }

    private func emit(_ files: [StagedFile]) {
        files.forEach { onPicked?(Picked($0)) }
    }
}
