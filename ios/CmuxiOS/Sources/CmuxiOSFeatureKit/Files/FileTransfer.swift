import Foundation

/// Seam for lane C4 (files). Transfers are chunked and resumable; progress
/// streams end after `.finished`, `.failed` or `.cancelled`.
public protocol FileTransfer: Sendable {
    func start(_ request: TransferRequest) async throws -> AsyncStream<TransferProgress>
    /// Resumes an interrupted transfer from the last acknowledged chunk.
    func resume(_ id: TransferID) async throws -> AsyncStream<TransferProgress>
    func cancel(_ id: TransferID) async
}
