import CmuxiOSFeatureKit
import CmuxMobileFiles
import CmuxMobileWire
import Foundation

/// The real `FileTransfer` (c4-files.md section 6): `MobileTransferManager`
/// over `CmuxLink` sessions from a `FileHostConnector`, with the journal in
/// Application Support so paused transfers survive a relaunch.
public actor LinkFileTransfer: FileTransfer {
    private let manager: MobileTransferManager

    public init(connector: any FileHostConnector, journalURL: URL?) {
        manager = MobileTransferManager(
            connector: { host in try await connector.client(for: HostID(host)) },
            journal: TransferJournal(fileURL: journalURL))
    }

    public static var defaultJournalURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux-next/transfers.json")
    }

    public func start(_ request: TransferRequest) async throws -> AsyncStream<TransferProgress> {
        Self.map(await manager.start(Self.request(request)))
    }

    public func resume(_ id: TransferID) async throws -> AsyncStream<TransferProgress> {
        Self.map(try await manager.resume(id.rawValue))
    }

    public func cancel(_ id: TransferID) async {
        await manager.cancel(id.rawValue)
    }

    public func pauseAll() async {
        await manager.pauseAll()
    }

    public func history() async -> [TransferSnapshot] {
        await manager.records().map(Self.snapshot)
    }

    // MARK: Mapping

    static func request(_ request: TransferRequest) -> MobileTransferRequest {
        let dest: FilesUploadDestination?
        switch request.direction {
        case .download:
            dest = nil
        case .upload:
            switch request.destination {
            case .terminal(let id): dest = FilesUploadDestination(kind: .terminal, terminal: id)
            case .composer: dest = FilesUploadDestination(kind: .composer)
            case .directory(let path): dest = FilesUploadDestination(kind: .path, path: path)
            }
        }
        return MobileTransferRequest(
            id: request.id.rawValue, hostID: request.hostID.rawValue, direction: request.isUpload ? .upload : .download,
            localURL: request.localURL, remotePath: request.remotePath, name: request.displayName,
            mime: request.mime ?? "application/octet-stream", dest: dest)
    }

    static func map(_ updates: AsyncStream<MobileTransferUpdate>) -> AsyncStream<TransferProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let task = Task {
                for await update in updates { continuation.yield(progress(update)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func progress(_ update: MobileTransferUpdate) -> TransferProgress {
        TransferProgress(id: TransferID(rawValue: update.id), completedBytes: Int64(update.completedBytes),
                         totalBytes: update.totalBytes.map(Int64.init), state: state(update.status), remotePath: update.resultPath,
                         uploadID: update.uploadID)
    }

    static func state(_ status: TransferStatus) -> TransferProgress.State {
        switch status {
        case .running: .running
        case .paused: .paused
        case .finished: .finished
        case .cancelled: .cancelled
        // The code travels as the reason; the list localizes known codes.
        case .failed(let code, _, let retryable): retryable ? .paused : .failed(reason: code)
        }
    }

    static func snapshot(_ record: TransferRecord) -> TransferSnapshot {
        let local = URL(fileURLWithPath: record.localPath)
        let destination: TransferDestination
        switch record.dest?.kind {
        case .terminal?: destination = .terminal(id: record.dest?.terminal)
        case .path?: destination = .directory(record.dest?.path ?? "")
        case .composer?, nil: destination = .composer
        }
        let request = TransferRequest(
            id: TransferID(rawValue: record.id), hostID: HostID(record.hostID),
            direction: record.direction == .upload ? .upload(localURL: local) : .download(localURL: local),
            remotePath: record.remotePath, byteCount: record.size.map(Int64.init), destination: destination,
            name: record.name, mime: record.mime)
        let progress = TransferProgress(id: request.id, completedBytes: Int64(record.completedBytes),
                                        totalBytes: record.size.map(Int64.init), state: state(record.status),
                                        remotePath: record.resultPath, uploadID: record.uploadID)
        return TransferSnapshot(request: request, progress: progress)
    }
}
