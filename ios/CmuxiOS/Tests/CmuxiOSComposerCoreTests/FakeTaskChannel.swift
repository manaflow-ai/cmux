import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import CmuxMobileWire
import Foundation

/// A scripted host channel on `task:<host>`.
actor FakeTaskChannel: WorkspaceControlChannel {
    private var state: WorkspaceChannelState
    private var stateSinks: [AsyncStream<WorkspaceChannelState>.Continuation] = []
    private var updateSink: AsyncStream<WorkspaceStreamUpdate>.Continuation?
    private var pending: [WorkspaceStreamUpdate] = []
    private(set) var submitted: [OpFrame] = []
    private(set) var snapshotRequests = 0
    private(set) var closed = false
    var answer: (@Sendable (OpFrame) throws -> WorkspaceOpOutcome)?

    init(state: WorkspaceChannelState = .live(path: "relay", caps: ["task.stream", "task.dispatch"])) {
        self.state = state
    }

    func states() -> AsyncStream<WorkspaceChannelState> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceChannelState.self, bufferingPolicy: .bufferingNewest(1))
        stateSinks.append(sink)
        sink.yield(state)
        return stream
    }

    func updates() -> AsyncStream<WorkspaceStreamUpdate> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceStreamUpdate.self)
        updateSink = sink
        for update in pending { sink.yield(update) }
        pending = []
        return stream
    }

    func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome {
        submitted.append(op)
        guard let answer else { throw WorkspaceChannelError.outcomeUnknown }
        return try answer(op)
    }

    func requestSnapshot() { snapshotRequests += 1 }

    func close() {
        closed = true
        updateSink?.finish()
        stateSinks.forEach { $0.finish() }
    }

    func setState(_ next: WorkspaceChannelState) {
        state = next
        stateSinks.forEach { $0.yield(next) }
    }

    func push(_ update: WorkspaceStreamUpdate) {
        if let updateSink { updateSink.yield(update) } else { pending.append(update) }
    }

    func setAnswer(_ answer: @escaping @Sendable (OpFrame) throws -> WorkspaceOpOutcome) { self.answer = answer }
}

/// One fake channel per host, created on demand.
final class FakeTaskChannels: WorkspaceChannelFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var made: [HostID: FakeTaskChannel] = [:]

    func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel {
        lock.withLock {
            if let existing = made[host.id] { return existing }
            let channel = FakeTaskChannel()
            made[host.id] = channel
            return channel
        }
    }

    func channel(_ host: HostID) -> FakeTaskChannel? { lock.withLock { made[host] } }
}

enum TaskFrames {
    static func snapshot(seq: UInt64, epoch: String = "ep_1", tasks: [JSONValue] = []) -> SnapshotFrame {
        SnapshotFrame(stream: "task:h_studio", seq: seq, state: .object([
            "agents": .array([
                .object(["id": "claude", "name": "Claude Code", "default_model": "opus", "models": .array([
                    .object(["id": "opus", "label": "Opus", "efforts": .array(["low", "medium", "high"]), "default_effort": "medium"]),
                ])]),
                .object(["id": "codex", "name": "Codex", "models": .array([]), "unavailable": "Not signed in"]),
            ]),
            "tasks": .array(tasks),
        ]), decided: [], epoch: epoch)
    }

    static func task(_ id: String, state: String = "queued") -> JSONValue {
        .object(["id": .string(id), "host": "h_studio", "workspace": "ws_studio1", "tab": "tab_a1", "agent": "claude",
                 "state": .string(state), "title": "Fix", "created_at": .int(1_791_331_208_000)])
    }

    static func state(seq: UInt64, task: String, state: String, epoch: String = "ep_1") -> EventFrame {
        EventFrame(stream: "task:h_studio", seq: seq, tx: "tx_\(seq)", op: "task.state.set",
                   params: .object(["task": .string(task), "state": .string(state), "at": .int(1)]),
                   actor: ["identity": "host:h_studio"], origin: .cli, at: 1, epoch: epoch)
    }
}

extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
}
