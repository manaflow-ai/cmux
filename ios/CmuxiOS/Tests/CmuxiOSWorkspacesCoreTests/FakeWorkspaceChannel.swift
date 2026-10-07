import CmuxMobileWire
import CmuxiOSWorkspacesCore
import Foundation

/// A scripted host socket: the test pushes states and frames, answers ops
/// and counts snapshot requests.
actor FakeWorkspaceChannel: WorkspaceControlChannel {
    private var stateSinks: [AsyncStream<WorkspaceChannelState>.Continuation] = []
    private var updateSinks: [AsyncStream<WorkspaceStreamUpdate>.Continuation] = []
    private var state: WorkspaceChannelState = .connecting
    private(set) var submitted: [OpFrame] = []
    private(set) var snapshotRequests = 0
    private(set) var closed = false
    /// Answers each op; nil throws `.notConnected`.
    var answer: (@Sendable (OpFrame) -> WorkspaceOpOutcome?)?
    private var subscribed: [CheckedContinuation<Void, Never>] = []

    func states() -> AsyncStream<WorkspaceChannelState> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceChannelState.self)
        sink.yield(state)
        stateSinks.append(sink)
        return stream
    }

    func updates() -> AsyncStream<WorkspaceStreamUpdate> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceStreamUpdate.self)
        updateSinks.append(sink)
        for waiter in subscribed { waiter.resume() }
        subscribed = []
        return stream
    }

    /// Returns once the source subscribed to updates.
    func waitForSubscriber() async {
        guard updateSinks.isEmpty else { return }
        await withCheckedContinuation { subscribed.append($0) }
    }

    func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome {
        submitted.append(op)
        guard let outcome = answer?(op) else { throw WorkspaceChannelError.notConnected }
        return outcome
    }

    func requestSnapshot() { snapshotRequests += 1 }

    func close() {
        closed = true
        stateSinks.forEach { $0.finish() }
        updateSinks.forEach { $0.finish() }
        stateSinks = []
        updateSinks = []
    }

    func reopenedForTest() { closed = false }

    func setAnswer(_ answer: (@Sendable (OpFrame) -> WorkspaceOpOutcome?)?) { self.answer = answer }

    func send(_ state: WorkspaceChannelState) {
        self.state = state
        stateSinks.forEach { $0.yield(state) }
    }

    func send(_ update: WorkspaceStreamUpdate) {
        updateSinks.forEach { $0.yield(update) }
    }
}
