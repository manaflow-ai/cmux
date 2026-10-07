import Foundation

/// A progress report for one transfer.
public struct TransferProgress: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case running
        case paused
        case finished
        case failed(reason: String)
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .running, .paused: false
            case .finished, .failed, .cancelled: true
            }
        }
    }

    public var id: TransferID
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var state: State
    /// A finished upload's path on the Mac.
    public var remotePath: String?
    /// A verified upload's owner-issued `up_` reference, used by task dispatch.
    public var uploadID: String?

    public init(id: TransferID, completedBytes: Int64, totalBytes: Int64?, state: State, remotePath: String? = nil,
                uploadID: String? = nil) {
        self.id = id
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.state = state
        self.remotePath = remotePath
        self.uploadID = uploadID
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}
