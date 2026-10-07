import Foundation

/// A `FileTransfer` that reports a transfer in eight equal chunks, yielding
/// between chunks instead of waiting on a clock. `failAfterChunks` makes the
/// next transfer stop there so resume paths can be exercised.
public actor MockFileTransfer: FileTransfer {
    public static let chunkCount = 8
    public static let defaultSize: Int64 = 1 << 20

    private var acknowledged: [TransferID: (completed: Int64, total: Int64)] = [:]
    private var requests: [TransferID: TransferRequest] = [:]
    private var cancelled: Set<TransferID> = []
    private var failAfterChunks: Int?

    public init(failAfterChunks: Int? = nil) {
        self.failAfterChunks = failAfterChunks
    }

    public func start(_ request: TransferRequest) async throws -> AsyncStream<TransferProgress> {
        acknowledged[request.id] = (0, request.byteCount ?? Self.defaultSize)
        requests[request.id] = request
        cancelled.remove(request.id)
        return run(request.id, failAfter: failAfterChunks.take())
    }

    public func resume(_ id: TransferID) async throws -> AsyncStream<TransferProgress> {
        guard acknowledged[id] != nil else { throw FeatureSourceError.notFound(id.rawValue) }
        cancelled.remove(id)
        return run(id, failAfter: nil)
    }

    public func cancel(_ id: TransferID) async {
        cancelled.insert(id)
    }

    private func run(_ id: TransferID, failAfter: Int?) -> AsyncStream<TransferProgress> {
        AsyncStream { continuation in
            let task = Task { await self.pump(id, failAfter: failAfter, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func pump(_ id: TransferID, failAfter: Int?, into continuation: AsyncStream<TransferProgress>.Continuation) async {
        defer { continuation.finish() }
        guard let start = acknowledged[id] else { return }
        let chunk = max(1, start.total / Int64(Self.chunkCount))
        var completed = start.completed
        var sent = 0
        while completed < start.total {
            if cancelled.contains(id) || Task.isCancelled {
                continuation.yield(TransferProgress(id: id, completedBytes: completed, totalBytes: start.total, state: .cancelled))
                return
            }
            if let failAfter, sent == failAfter {
                continuation.yield(TransferProgress(id: id, completedBytes: completed, totalBytes: start.total,
                                                    state: .failed(reason: "Connection lost")))
                return
            }
            completed = min(start.total, completed + chunk)
            sent += 1
            acknowledged[id] = (completed, start.total)
            continuation.yield(TransferProgress(id: id, completedBytes: completed, totalBytes: start.total, state: .running))
            await Task.yield()
        }
        let request = requests[id]
        let remote = request.flatMap { $0.isUpload ? "/Users/mock/Downloads/cmux-phone/\($0.displayName)" : nil }
        continuation.yield(TransferProgress(id: id, completedBytes: completed, totalBytes: start.total, state: .finished,
                                            remotePath: remote, uploadID: remote.map { _ in "up_" + id.rawValue.replacingOccurrences(of: "-", with: "") }))
    }
}

private extension Optional {
    /// Returns the value and leaves nil behind.
    mutating func take() -> Wrapped? {
        defer { self = nil }
        return self
    }
}
