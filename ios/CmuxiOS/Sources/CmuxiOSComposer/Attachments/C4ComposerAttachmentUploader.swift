import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import Foundation

/// C8's attachment uploader backed by C4's transfer list.
///
/// The transfer coordinator returns the Mac's verified `up_…` reference. A
/// remote path is intentionally not copied into the composer draft; the task
/// dispatch only accepts the owner-issued reference.
actor C4ComposerAttachmentUploader: ComposerAttachmentUploading {
    private let sender: FileSendCoordinator

    init(sender: FileSendCoordinator) {
        self.sender = sender
    }

    func upload(localURL: URL, name: String, mime: String, to host: HostID)
        async -> AsyncStream<ComposerAttachment> {
        await MainActor.run {
            AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
                let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let staged = StagedFile(url: localURL, name: name, mime: mime, byteCount: fileSize)
                let fallbackID = TransferID()
                let transferID = sender.uploadAttachment(staged, host: host) { attachment in
                    let id = attachment?.id ?? fallbackID
                    guard let attachment,
                          let uploadID = attachment.uploadID,
                          Self.isValidUploadID(uploadID) else {
                        continuation.yield(ComposerAttachment(id: id, name: name, mime: mime,
                                                              byteCount: fileSize, phase: .failed))
                        continuation.finish()
                        return
                    }
                    continuation.yield(ComposerAttachment(id: id, name: name, mime: mime,
                                                          byteCount: fileSize, uploadID: uploadID, phase: .ready))
                    continuation.finish()
                }
                continuation.onTermination = { [weak sender] termination in
                    guard case .cancelled = termination else { return }
                    Task { @MainActor in sender?.cancel(transferID) }
                }
            }
        }
    }

    private static func isValidUploadID(_ value: String) -> Bool {
        guard value.hasPrefix("up_") else { return false }
        let suffix = value.dropFirst(3)
        return (2...64).contains(suffix.count)
            && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
