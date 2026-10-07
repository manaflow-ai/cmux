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

    public init(id: TransferID, completedBytes: Int64, totalBytes: Int64?, state: State) {
        self.id = id
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.state = state
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }
}
