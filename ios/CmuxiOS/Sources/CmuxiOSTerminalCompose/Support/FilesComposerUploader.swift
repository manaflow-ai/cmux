import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import CmuxiOSTerminalComposeCore

/// The composer's uploads over C4's `FileSendCoordinator`: into the Mac's
/// inbox, path back per upload; the transfer list shows them like any other.
@MainActor
final class FilesComposerUploader: TerminalComposerUploading {
    private let sender: FileSendCoordinator

    init(sender: FileSendCoordinator) {
        self.sender = sender
    }

    func upload(_ file: ComposerUploadFile, to host: HostID) async -> String? {
        let staged = StagedFile(url: file.url, name: file.name, mime: file.mime, byteCount: file.byteCount)
        return await withCheckedContinuation { continuation in
            sender.upload(staged, host: host) { path in continuation.resume(returning: path) }
        }
    }
}

extension ComposerUploadFile {
    init(_ staged: StagedFile) {
        self.init(url: staged.url, name: staged.name, mime: staged.mime, byteCount: staged.byteCount)
    }
}
