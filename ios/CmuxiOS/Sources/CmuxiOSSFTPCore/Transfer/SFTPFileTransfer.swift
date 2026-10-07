public import CmuxiOSFeatureKit
import CmuxMobileSSH
public import Foundation

/// C4's `FileTransfer` for SSH hosts (lane E5): uploads and downloads over
/// the host's SFTP session from `SFTPHostDirectory`. Progress per
/// acknowledged chunk; a dropped session pauses the transfer, and resume
/// continues where the bytes end (local size for downloads, remote size for
/// uploads). The history lives in memory: SSH transfers end with their
/// session, and the list restarts them after a relaunch if the user asks.
public actor SFTPFileTransfer: FileTransfer {
    private struct Record {
        var request: TransferRequest
        var progress: TransferProgress
        var task: Task<Void, Never>?
        var continuation: AsyncStream<TransferProgress>.Continuation?
        /// Set by cancel and pause so the run reports that state, not a failure.
        var stopping: TransferProgress.State?
    }

    private let directory: SFTPHostDirectory
    private var records: [TransferID: Record] = [:]
    private var order: [TransferID] = []

    public init(directory: SFTPHostDirectory) {
        self.directory = directory
    }

    public func start(_ request: TransferRequest) async throws -> AsyncStream<TransferProgress> {
        if records[request.id] == nil { order.append(request.id) }
        records[request.id] = Record(request: request, progress: TransferProgress(
            id: request.id, completedBytes: 0, totalBytes: request.byteCount, state: .running))
        return run(request.id, resume: false)
    }

    public func resume(_ id: TransferID) async throws -> AsyncStream<TransferProgress> {
        guard let record = records[id] else { throw FeatureSourceError.offline }
        // Paused and failed transfers resume; finished and cancelled ones are done.
        guard record.task == nil, record.progress.state != .finished, record.progress.state != .cancelled else {
            throw FeatureSourceError.offline
        }
        return run(id, resume: true)
    }

    public func cancel(_ id: TransferID) async {
        guard var record = records[id] else { return }
        if let task = record.task {
            record.stopping = .cancelled
            records[id] = record
            task.cancel()
        } else if !record.progress.state.isTerminal {
            report(id, state: .cancelled, completed: record.progress.completedBytes)
            finishStream(id)
        }
    }

    public func pauseAll() async {
        for (id, record) in records where record.task != nil {
            records[id]?.stopping = .paused
            record.task?.cancel()
        }
    }

    public func history() async -> [TransferSnapshot] {
        order.reversed().compactMap { id in
            records[id].map { TransferSnapshot(request: $0.request, progress: $0.progress) }
        }
    }

    // MARK: Running

    private func run(_ id: TransferID, resume: Bool) -> AsyncStream<TransferProgress> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferProgress.self, bufferingPolicy: .bufferingNewest(32))
        records[id]?.continuation?.finish()
        records[id]?.continuation = continuation
        records[id]?.stopping = nil
        report(id, state: .running, completed: records[id]?.progress.completedBytes ?? 0)
        records[id]?.task = Task { await self.execute(id, resume: resume) }
        return stream
    }

    private func execute(_ id: TransferID, resume: Bool) async {
        guard let request = records[id]?.request, let continuation = records[id]?.continuation else { return }
        let total = request.byteCount
        let counter = SFTPProgressCounter(records[id]?.progress.completedBytes ?? 0)
        let progress: @Sendable (SFTPTransferProgress) -> Void = { update in
            counter.set(Int64(update.bytesTransferred))
            continuation.yield(TransferProgress(id: id, completedBytes: Int64(update.bytesTransferred),
                                                totalBytes: update.totalBytes.map(Int64.init) ?? total, state: .running))
        }
        do {
            let remote = try await directory.run(request.hostID) { system in
                try await Self.transfer(request, on: system, resume: resume, progress: progress)
            }
            records[id]?.task = nil
            report(id, state: .finished, completed: counter.value, remotePath: remote)
        } catch {
            records[id]?.task = nil
            let state: TransferProgress.State
            if let stopping = records[id]?.stopping {
                state = stopping
            } else if let reason = SFTPTransferFailure.reason(for: error) {
                state = .failed(reason: reason)
            } else {
                state = .paused
            }
            if state == .cancelled, case .download(let local) = request.direction {
                try? FileManager.default.removeItem(at: local)
            }
            report(id, state: state, completed: counter.value)
        }
        finishStream(id)
    }

    /// Runs one transfer and returns the remote path it read or wrote.
    static func transfer(_ request: TransferRequest, on system: any SFTPFileSystem, resume: Bool,
                         progress: @escaping @Sendable (SFTPTransferProgress) -> Void) async throws -> String {
        switch request.direction {
        case .download(let local):
            let offset = resume ? Self.localSize(local) : 0
            try await system.download(request.remotePath, to: local, resumeFrom: offset, progress: progress)
            return request.remotePath
        case .upload(let local):
            let folder: String
            if case .directory(let path) = request.destination {
                folder = path
            } else {
                folder = try await system.realpath(".")
            }
            let remote = folder.hasSuffix("/") ? folder + request.displayName : folder + "/" + request.displayName
            let offset = resume ? ((try? await system.stat(remote))?.size ?? 0) : 0
            try await system.upload(from: local, to: remote, resumeFrom: offset, progress: progress)
            return remote
        }
    }

    static func localSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func report(_ id: TransferID, state: TransferProgress.State, completed: Int64, remotePath: String? = nil) {
        guard var record = records[id] else { return }
        record.progress.state = state
        record.progress.completedBytes = completed
        if let remotePath { record.progress.remotePath = remotePath }
        records[id] = record
        record.continuation?.yield(record.progress)
    }

    private func finishStream(_ id: TransferID) {
        records[id]?.continuation?.finish()
        records[id]?.continuation = nil
    }
}
