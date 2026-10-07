public import CmuxMobileWire
import Foundation

/// A channel with no carrier: offline with a reason, refuses every op.
/// The real source uses it while no control-plane client is registered,
/// so paired Macs show as unreachable instead of as fake data.
public struct UnavailableWorkspaceChannel: WorkspaceControlChannel {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public func states() async -> AsyncStream<WorkspaceChannelState> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceChannelState.self)
        continuation.yield(.offline(reason: reason))
        // Kept open so the subscriber does not read "finished" as a change.
        continuation.onTermination = { _ in }
        return stream
    }

    public func updates() async -> AsyncStream<WorkspaceStreamUpdate> {
        AsyncStream { _ in }
    }

    public func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome {
        throw WorkspaceChannelError.notConnected
    }

    public func requestSnapshot() async {}
    public func close() async {}
}
