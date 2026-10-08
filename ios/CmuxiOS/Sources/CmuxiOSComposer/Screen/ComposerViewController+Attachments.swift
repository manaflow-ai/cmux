import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import UIKit

extension ComposerViewController {
    /// Uploads a picked file to the target Mac through C4 and tracks it in the draft.
    func upload(_ picked: ComposerAttachmentPicker.Picked) {
        guard let uploader = feature.uploader, let host = session.draft?.target.hostID else {
            picker?.discard(picked)
            return
        }
        let size = picked.byteCount
        let placeholder = ComposerAttachment(id: TransferID(), name: picked.name, mime: picked.mime, byteCount: size)
        session.upsertAttachment(placeholder)
        let id = placeholder.id
        uploads[id] = Task { [weak self] in
            for await progress in await uploader.upload(localURL: picked.url, name: picked.name, mime: picked.mime, to: host) {
                guard !Task.isCancelled, let self else { return }
                var update = progress
                update.id = id
                self.session.upsertAttachment(update)
            }
            self?.uploads[id] = nil
        }
    }

    func removeAttachment(_ id: TransferID) {
        uploads[id]?.cancel()
        uploads[id] = nil
        session.removeAttachment(id)
    }
}
