import CmuxiOSComposerCore
import CmuxiOSFeatureKit
@preconcurrency import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Picks photos (PHPicker, no library permission needed) or files (document
/// picker), copies each into a temporary file the app owns, and hands it to
/// the uploader (lane C4). One picker session at a time.
@MainActor
final class ComposerAttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    /// A local copy ready to upload.
    struct Picked: Sendable {
        var url: URL
        var name: String
        var mime: String
    }

    var onPicked: ((Picked) -> Void)?

    func presentPhotos(from presenter: UIViewController) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 10
        configuration.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func presentFiles(from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
            let suggested = provider.suggestedName
            _ = provider.loadFileRepresentation(for: type) { [weak self] url, _, _ in
                // The provider deletes `url` when this returns: copy now, off the main thread.
                guard let url, let copy = Self.copyToTemporary(url, suggested: suggested) else { return }
                let picked = Picked(url: copy, name: copy.lastPathComponent, mime: type.preferredMIMEType ?? "image/jpeg")
                Task { @MainActor [weak self] in self?.onPicked?(picked) }
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            onPicked?(Picked(url: url, name: url.lastPathComponent, mime: type.preferredMIMEType ?? "application/octet-stream"))
        }
    }

    private nonisolated static func copyToTemporary(_ url: URL, suggested: String?) -> URL? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let base = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + base + ext)
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
