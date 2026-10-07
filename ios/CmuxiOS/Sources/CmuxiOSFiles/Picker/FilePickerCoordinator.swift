import AVFoundation
import CmuxiOSFilesCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Photos (PHPicker, no library permission), camera and the document picker,
/// each ending in staged copies the app owns (c4-files.md section 6).
@MainActor
public final class FilePickerCoordinator: NSObject {
    public typealias Completion = @MainActor ([StagedFile]) -> Void

    private let stager: FileStager
    private let preferences: FileTransferPreferences
    private var completion: Completion?

    public init(stager: FileStager = FileStager(), preferences: FileTransferPreferences = FileTransferPreferences()) {
        self.stager = stager
        self.preferences = preferences
    }

    /// An action sheet with the three sources.
    public func presentSourceMenu(from presenter: UIViewController, anchor: UIBarButtonItem? = nil,
                                  completion: @escaping Completion) {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: String(localized: "files.pick.photos", defaultValue: "Photo Library", bundle: .module), style: .default) { _ in
            self.presentPhotos(from: presenter, completion: completion)
        })
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            sheet.addAction(UIAlertAction(
                title: String(localized: "files.pick.camera", defaultValue: "Take Photo", bundle: .module), style: .default) { _ in
                self.presentCamera(from: presenter, completion: completion)
            })
        }
        sheet.addAction(UIAlertAction(
            title: String(localized: "files.pick.document", defaultValue: "Choose File", bundle: .module), style: .default) { _ in
            self.presentDocuments(from: presenter, completion: completion)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "files.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = anchor
        if anchor == nil {
            sheet.popoverPresentationController?.sourceView = presenter.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                                                                     width: 1, height: 1)
        }
        presenter.present(sheet, animated: true)
    }

    public func presentPhotos(from presenter: UIViewController, completion: @escaping Completion) {
        self.completion = completion
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 10
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    public func presentCamera(from presenter: UIViewController, completion: @escaping Completion) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            presentCameraDenied(from: presenter)
            return
        default:
            break
        }
        self.completion = completion
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    public func presentDocuments(from presenter: UIViewController, completion: @escaping Completion) {
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func presentCameraDenied(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: String(localized: "files.camera.denied.title", defaultValue: "Camera Access Is Off", bundle: .module),
            message: String(localized: "files.camera.denied.message",
                            defaultValue: "Allow camera access for cmux in Settings to take photos for your Mac.", bundle: .module),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "files.openSettings", defaultValue: "Open Settings", bundle: .module),
                                      style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: String(localized: "files.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        presenter.present(alert, animated: true)
    }

    private func finish(_ files: [StagedFile]) {
        let completion = completion
        self.completion = nil
        if !files.isEmpty { completion?(files) }
    }

    /// Stages each PHPicker result off the main actor; the provider's file
    /// URL only lives inside its callback, so the copy happens there. Also
    /// stages pasted and dropped items for the terminal composer (E4).
    /// Runs on the caller's actor (`nonisolated(nonsending)`): the provider
    /// is not Sendable, so it never leaves the caller; only the copy in the
    /// load callback runs elsewhere.
    public nonisolated(nonsending) static func stage(_ provider: NSItemProvider, stager: FileStager, convertHEIC: Bool) async -> StagedFile? {
        let type = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .data)
        }
        guard let type else { return nil }
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let named = name.map { $0 + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)") }
                continuation.resume(returning: try? stager.stage(copying: url, name: named, convertHEIC: convertHEIC))
            }
        }
    }
}

extension FilePickerCoordinator: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider)
        let stager = stager
        let convert = preferences.convertHEIC
        Task {
            var files: [StagedFile] = []
            for provider in providers {
                if let file = await Self.stage(provider, stager: stager, convertHEIC: convert) { files.append(file) }
            }
            self.finish(files)
        }
    }
}

extension FilePickerCoordinator: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let stager = stager
        // `asCopy` already made app-owned copies: move them, off the main actor.
        Task {
            let files = await Task.detached { urls.compactMap { try? stager.stage(moving: $0, convertHEIC: false) } }.value
            self.finish(files)
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }
}

extension FilePickerCoordinator: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    public func imagePickerController(_ picker: UIImagePickerController,
                                      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
            completion = nil
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Photo \(formatter.string(from: Date())).jpg"
        finish([try? stager.stage(data: data, name: name)].compactMap { $0 })
    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        completion = nil
    }
}
