import Foundation

/// Seam for lane C4 (files; c4-files.md). Transfers are chunked, sha256
/// verified and resumable; progress streams end after `.finished`,
/// `.failed`, `.cancelled` or `.paused`.
public protocol FileTransfer: Sendable {
    func start(_ request: TransferRequest) async throws -> AsyncStream<TransferProgress>
    /// Resumes an interrupted transfer from the bytes the receiver holds.
    func resume(_ id: TransferID) async throws -> AsyncStream<TransferProgress>
    func cancel(_ id: TransferID) async
    /// Transfers kept from earlier runs (paused ones resume), newest first.
    func history() async -> [TransferSnapshot]
    /// Stops running transfers as paused (the app is being suspended).
    func pauseAll() async
}

extension FileTransfer {
    public func history() async -> [TransferSnapshot] { [] }
    public func pauseAll() async {}
}
