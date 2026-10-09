public import CmuxMobileWire

/// One owner frame of `workspace:<host>`, in stream order. The same shape as
/// the control-plane client's `StreamUpdate` (lane B1).
public enum WorkspaceStreamUpdate: Hashable, Sendable {
    case snapshot(SnapshotFrame)
    case event(EventFrame)
}
