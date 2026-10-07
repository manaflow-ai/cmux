public import CmuxMobileWire

/// The owner's decision on one op (lane B1's `OpOutcome`).
public enum WorkspaceOpOutcome: Hashable, Sendable {
    case applied(ResultFrame)
    case rejected(RejectFrame)
}
