import Foundation

/// A Cloud machine's lifecycle state as `CloudDO` records it
/// (cloud-client-contract.md 1.2). The phone never derives it.
public enum CloudMachineStatus: String, Hashable, Sendable, CaseIterable {
    case provisioning
    case starting
    case running
    case pausing
    case paused
    case deleting
    case failed

    /// Between two stable states; actions wait for the owner's next upsert.
    public var isTransitioning: Bool {
        switch self {
        case .provisioning, .starting, .pausing, .deleting: true
        case .running, .paused, .failed: false
        }
    }
}
