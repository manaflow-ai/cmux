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
    /// Per-upload completions (the terminal composer): the Mac path, or nil
    /// when the upload ended without finishing.
    private var completions: [TransferID: @MainActor (String?) -> Void] = [:]
    /// Task-composer completions receive the verified owner reference as well
    /// as the Mac path. Keeping this separate from the terminal path callback
    /// preserves the existing API while letting C8 retain only `up_…` ids.
    private var attachmentCompletions: [TransferID: @MainActor (FileAttachment?) -> Void] = [:]

    public init(model: TransferListModel, paster: (any TerminalPathPaster)?, attachments: (any FileAttachmentSink)?,
                stager: FileStager = FileStager()) {
        self.model = model
        self.paster = paster
        self.attachments = attachments
        self.stager = stager
        model.onFinished = { [weak self] item in self?.finished(item) }
        model.onEnded = { [weak self] item in self?.ended(item) }
    }

    /// Starts one upload per file; returns their ids in order.
    @discardableResult
    public func send(_ files: [StagedFile], to target: FileSendTarget, host: HostID) -> [TransferID] {
        files.map { file in
            start(file, to: target, host: host)
        }
    }

    /// Uploads one file to the Mac's inbox (`dest.kind = composer`) and
    /// calls `completion` once with its path there, or nil when it ended
    /// without finishing. The staged copy is discarded either way.
    @discardableResult
    public func upload(_ file: StagedFile, host: HostID, completion: @escaping @MainActor (String?) -> Void) -> TransferID {
        start(file, to: .inbox, host: host, completion: completion)
    }

    /// Uploads one file for a task composer and returns its verified C4
    /// attachment metadata. The callback is invoked exactly once with `nil`
    /// when the transfer ends without a verified upload.
    @discardableResult
    public func uploadAttachment(_ file: StagedFile, host: HostID,
                                 completion: @escaping @MainActor (FileAttachment?) -> Void) -> TransferID {
        start(file, to: .inbox, host: host, attachmentCompletion: completion)
    }

    /// Cancels a transfer started by this coordinator. The transfer model will
    /// settle the row and invoke the registered completion with `nil`.
    public func cancel(_ id: TransferID) {
        model.cancel(id)
    }

    /// Cancelled or failed for good: drop the staged copy.
    private func ended(_ item: TransferItem) {
        guard item.progress.state != .finished, let entry = pending.removeValue(forKey: item.id) else { return }
        stager.discard(entry.file)
        completions.removeValue(forKey: item.id)?(nil)
        attachmentCompletions.removeValue(forKey: item.id)?(nil)
    }

    private func finished(_ item: TransferItem) {
        guard let entry = pending.removeValue(forKey: item.id) else { return }
        stager.discard(entry.file)
        let completion = completions.removeValue(forKey: item.id)
        let attachmentCompletion = attachmentCompletions.removeValue(forKey: item.id)
        guard let path = item.progress.remotePath else {
            completion?(nil)
            attachmentCompletion?(nil)
            return
        }
        let attachment = FileAttachment(id: item.id, hostID: item.request.hostID, remotePath: path,
                                        name: entry.file.name, mime: entry.file.mime,
                                        byteCount: entry.file.byteCount, uploadID: item.progress.uploadID)
        attachmentCompletion?(attachment)
        if let completion {
            completion(path)
            return
        }
        let host = item.request.hostID
        switch entry.target {
        case .terminal(let id):
            guard let paster else { return }
            Task { await paster.paste(path: path, terminal: id, host: host) }
        case .composer:
            guard let attachments else { return }
            let attachment = FileAttachment(id: item.id, hostID: host, remotePath: path, name: entry.file.name,
                                            mime: entry.file.mime, byteCount: entry.file.byteCount, uploadID: item.progress.uploadID)
            Task { await attachments.attach(attachment) }
        case .inbox, .directory:
            break
        }
    }

    private func start(_ file: StagedFile, to target: FileSendTarget, host: HostID,
                       completion: (@MainActor (String?) -> Void)? = nil,
                       attachmentCompletion: (@MainActor (FileAttachment?) -> Void)? = nil) -> TransferID {
        let destination: TransferDestination
        switch target {
        case .terminal(let id): destination = .terminal(id: id)
        case .composer, .inbox: destination = .composer
        case .directory(let path): destination = .directory(path)
        }
        let request = TransferRequest(hostID: host, direction: .upload(localURL: file.url), byteCount: file.byteCount,
                                      destination: destination, name: file.name, mime: file.mime)
        pending[request.id] = (target, file)
        if let completion { completions[request.id] = completion }
        if let attachmentCompletion { attachmentCompletions[request.id] = attachmentCompletion }
        model.start(request)
        return request.id
    }
}
