public import CmuxMobileWire

/// One host's workspace stream on the control plane (b1-control-do.md:
/// `/v1/wire/host/<host>`, stream `workspace:<host>`, owner the Mac,
/// mirrored and forwarded by `HostDO`). Lane B1's `ControlPlaneClient`
/// adapts to this one to one; tests use a fake.
///
/// Contract:
/// - `states()` yields the current state first, then every change.
/// - `updates()` yields a snapshot first (and again after every
///   `requestSnapshot()` or reconnect), then events in seq order. The
///   receiver checks contiguity itself.
/// - `submit` sends the op once and returns the owner's result or reject;
///   it throws when there is no live socket (nothing queues) or when the
///   socket closed with the outcome unknown.
public protocol WorkspaceControlChannel: Sendable {
    func states() async -> AsyncStream<WorkspaceChannelState>
    func updates() async -> AsyncStream<WorkspaceStreamUpdate>
    func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome
    /// Asks the owner for a fresh snapshot (a revision gap was seen).
    func requestSnapshot() async
    /// Ends the subscription; the streams finish.
    func close() async
}
