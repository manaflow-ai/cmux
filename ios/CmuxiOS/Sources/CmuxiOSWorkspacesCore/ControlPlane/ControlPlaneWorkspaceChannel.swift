public import CmuxControlPlane
public import CmuxiOSFeatureKit
public import CmuxMobileWire
import Foundation

/// `WorkspaceControlChannel` over B1's `ControlPlaneClient` for one host.
///
/// Subscribes `workspace:<host>` (the Mac's store, mirrored by `HostDO`)
/// and `host:<host>` (presence and the Mac's caps). The channel is live
/// only while the socket is negotiated and the Mac is `online`; sleeping,
/// paused or disconnected Macs refuse ops (nothing queues). When the Mac
/// comes back online, undecided ops are resent with their keys.
///
/// `streamKind` picks the Mac-owned stream: `workspace` (C5) or `task` (C8's
/// composer, `task:<host>`); both have the same mirror and op semantics.
public actor ControlPlaneWorkspaceChannel: WorkspaceControlChannel {
    private let hostID: HostID
    private let streamKind: String
    private let reasons: ControlPlaneChannelReasons
    private let makeClient: @Sendable () async throws -> ControlPlaneClient
    private var client: ControlPlaneClient?
    private var starter: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var updatePump: Task<Void, Never>?
    private var socket: ControlPlaneState = .idle
    private var host = HostPresenceMirror()
    private var failure: String?
    private var state: WorkspaceChannelState = .connecting
    private var stateSinks: [UUID: AsyncStream<WorkspaceChannelState>.Continuation] = [:]
    private var updateSink: AsyncStream<WorkspaceStreamUpdate>.Continuation?
    private var closed = false

    public init(hostID: HostID, reasons: ControlPlaneChannelReasons, streamKind: String = "workspace",
                makeClient: @escaping @Sendable () async throws -> ControlPlaneClient) {
        self.hostID = hostID
        self.streamKind = streamKind
        self.reasons = reasons
        self.makeClient = makeClient
    }

    var workspaceStream: String { streamKind + ":" + hostID.rawValue }
    var hostStream: String { "host:" + hostID.rawValue }

    // MARK: WorkspaceControlChannel

    public func states() -> AsyncStream<WorkspaceChannelState> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceChannelState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        stateSinks[id] = sink
        sink.onTermination = { [weak self] _ in Task { await self?.dropStateSink(id) } }
        sink.yield(state)
        start()
        return stream
    }

    public func updates() -> AsyncStream<WorkspaceStreamUpdate> {
        let (stream, sink) = AsyncStream.makeStream(of: WorkspaceStreamUpdate.self)
        updateSink?.finish()
        updateSink = sink
        if let client { pumpWorkspace(client) }
        start()
        return stream
    }

    public func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome {
        guard case .live = state, let client else { throw WorkspaceChannelError.notConnected }
        do {
            switch try await client.submit(op) {
            case .applied(let result): return .applied(result)
            case .rejected(let reject): return .rejected(reject)
            }
        } catch ControlPlaneError.notConnected {
            throw WorkspaceChannelError.notConnected
        } catch {
            throw WorkspaceChannelError.outcomeUnknown
        }
    }

    /// Resubscribes the workspace stream: the owner answers with a snapshot.
    public func requestSnapshot() {
        guard let client else { return }
        pumpWorkspace(client)
    }

    public func close() async {
        closed = true
        starter?.cancel()
        tasks.forEach { $0.cancel() }
        updatePump?.cancel()
        tasks = []
        updatePump = nil
        let client = self.client
        self.client = nil
        await client?.stop()
        updateSink?.finish()
        updateSink = nil
        for sink in stateSinks.values { sink.finish() }
        stateSinks = [:]
    }

    // MARK: Session

    private func start() {
        guard starter == nil, !closed else { return }
        starter = Task { [weak self] in await self?.connect() }
    }

    private func connect() async {
        let made: ControlPlaneClient
        do {
            made = try await makeClient()
        } catch {
            failure = reasons.signedOut
            publish()
            return
        }
        guard !closed else { return }
        client = made
        await made.start()
        let states = made.states
        tasks.append(Task { [weak self] in
            for await state in states { await self?.socketChanged(state) }
        })
        let hostUpdates = await made.subscribe(hostStream)
        tasks.append(Task { [weak self] in
            for await update in hostUpdates { await self?.hostChanged(update) }
        })
        if updateSink != nil { pumpWorkspace(made) }
    }

    private func pumpWorkspace(_ client: ControlPlaneClient) {
        updatePump?.cancel()
        let stream = workspaceStream
        updatePump = Task { [weak self] in
            let updates = await client.subscribe(stream)
            for await update in updates { await self?.forward(update) }
        }
    }

    private func forward(_ update: StreamUpdate) {
        switch update {
        case .snapshot(let frame): updateSink?.yield(.snapshot(frame))
        case .event(let frame): updateSink?.yield(.event(frame))
        }
    }

    private func socketChanged(_ next: ControlPlaneState) async {
        socket = next
        if case .failed = next { failure = reasons.refused }
        if case .connected = next, let client {
            // Viewers > 0 lets the Mac send preview lines (c5-workspaces.md 2).
            try? await client.setPresence(active: true)
        }
        publish()
    }

    private func hostChanged(_ update: StreamUpdate) async {
        let wasOnline = host.presence == "online"
        switch update {
        case .snapshot(let frame): host.apply(snapshot: frame)
        case .event(let frame): host.apply(event: frame)
        }
        if !wasOnline, host.presence == "online", let client { await client.resendPending() }
        publish()
    }

    private func publish() {
        let next = Self.state(socket: socket, presence: host.presence, caps: host.caps, failure: failure, reasons: reasons)
        guard next != state else { return }
        state = next
        for sink in stateSinks.values { sink.yield(next) }
    }

    /// The channel state from the socket and the Mac's presence (pure).
    static func state(socket: ControlPlaneState, presence: String?, caps: Set<String>, failure: String?,
                      reasons: ControlPlaneChannelReasons) -> WorkspaceChannelState {
        switch socket {
        case .connected:
            switch presence {
            case "online": return .live(path: "relay", caps: caps)
            case "sleeping": return .offline(reason: reasons.macSleeping)
            case "paused": return .offline(reason: reasons.macPaused)
            case nil: return .connecting
            default: return .offline(reason: reasons.macOffline)
            }
        case .idle, .connecting:
            return failure.map { .offline(reason: $0) } ?? .connecting
        case .disconnected, .stopped:
            return .offline(reason: nil)
        case .failed:
            return .offline(reason: failure ?? reasons.refused)
        }
    }

    private func dropStateSink(_ id: UUID) { stateSinks[id] = nil }
}
