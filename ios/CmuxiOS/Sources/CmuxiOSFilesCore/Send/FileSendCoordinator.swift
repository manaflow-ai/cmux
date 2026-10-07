import CmuxiOSFeatureKit
import Foundation

/// The shared path behind "Send to terminal", "Attach to task" and "Save to
/// Mac" (c4-files.md section 6): starts the uploads on the list model and,
/// when one finishes, pastes its path or hands it to the composer. Staged
/// copies are discarded once their upload ends.
@MainActor
public final class FileSendCoordinator {
    public let model: TransferListModel
    private let paster: (any TerminalPathPaster)?
    private let attachments: (any FileAttachmentSink)?
    private let stager: FileStager
    private var pending: [TransferID: (target: FileSendTarget, file: StagedFile)] = [:]

    public init(model: TransferListModel, paster: (any TerminalPathPaster)?, attachments: (any FileAttachmentSink)?,
                stager: FileStager = FileStager()) {
        self.model = model
        self.paster = paster
        self.attachments = attachments
        self.stager = stager
        model.onFinished = { [weak self] item in self?.finished(item) }
    }

    /// Starts one upload per file; returns their ids in order.
    @discardableResult
    public func send(_ files: [StagedFile], to target: FileSendTarget, host: HostID) -> [TransferID] {
        files.map { file in
            let destination: TransferDestination
            switch target {
            case .terminal(let id): destination = .terminal(id: id)
            case .composer, .inbox: destination = .composer
            }
            let request = TransferRequest(hostID: host, direction: .upload(localURL: file.url), byteCount: file.byteCount,
                                          destination: destination, name: file.name, mime: file.mime)
            pending[request.id] = (target, file)
            model.start(request)
            return request.id
        }
    }

    private func finished(_ item: TransferItem) {
        guard let entry = pending.removeValue(forKey: item.id) else { return }
        stager.discard(entry.file)
        guard let path = item.progress.remotePath else { return }
        let host = item.request.hostID
        switch entry.target {
        case .terminal(let id):
            guard let paster else { return }
            Task { await paster.paste(path: path, terminal: id, host: host) }
        case .composer:
            guard let attachments else { return }
            let attachment = FileAttachment(id: item.id, hostID: host, remotePath: path, name: entry.file.name,
                                            mime: entry.file.mime, byteCount: entry.file.byteCount)
            Task { await attachments.attach(attachment) }
        case .inbox:
            break
        }
    }
}
