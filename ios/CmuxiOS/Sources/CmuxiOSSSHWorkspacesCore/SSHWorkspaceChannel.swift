public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
public import CmuxiOSWorkspacesCore
public import CmuxMobileWire
import Foundation

/// An SSH host's workspace stream (e3-workspaces.md section 6): each
/// discovery run becomes one snapshot of `workspace:<host>`. Discovery runs
/// when the list subscribes, on `requestSnapshot()` and when an attached
/// terminal of the host ends; never on a timer. The host is a read-only
/// projection: every op is refused.
public actor SSHWorkspaceChannel: WorkspaceControlChannel {
    /// Makes the runner for one run (resolving the host chain and login
    /// fresh, so an edited host takes effect); throws `SSHSessionFailure`.
    public typealias RunnerFactory = @Sendable () async throws -> any SSHCommandRunning

    private let hostID: HostID
    private let makeRunner: RunnerFactory
    private let catalog: SSHSessionCatalog
    private let reasons: SSHWorkspaceReasons
    private let discovery = SSHSessionDiscovery()
    private var state: WorkspaceChannelState = .connecting
    private var stateSinks: [UUID: AsyncStream<WorkspaceChannelState>.Continuation] = [:]
    private var updateSinks: [UUID: AsyncStream<WorkspaceStreamUpdate>.Continuation] = [:]
    private var seq: UInt64 = 0
    private var running: Task<Void, Never>?
    private var rerun = false
    private var endings: Task<Void, Never>?
    private var closed = false

    public init(hostID: HostID, catalog: SSHSessionCatalog, reasons: SSHWorkspaceReasons, makeRunner: @escaping RunnerFactory) {
        self.hostID = hostID
        self.catalog = catalog
        self.reasons = reasons
        self.makeRunner = makeRunner
    }

    public var stream: String { "workspace:" + hostID.rawValue }

    // MARK: WorkspaceControlChannel

    public func states() -> AsyncStream<WorkspaceChannelState> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceChannelState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        stateSinks[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropState(id) } }
        continuation.yield(state)
        return stream
    }

    public func updates() async -> AsyncStream<WorkspaceStreamUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceStreamUpdate.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        updateSinks[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropUpdates(id) } }
        await startListening()
        refresh()
        return stream
    }

    public func submit(_ op: OpFrame) async throws -> WorkspaceOpOutcome {
        .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: "proto.unsupported",
                              message: "SSH sessions are read-only", retryable: false, replayed: false))
    }

    public func requestSnapshot() { refresh() }

    public func close() {
        closed = true
        running?.cancel()
        endings?.cancel()
        stateSinks.values.forEach { $0.finish() }
        updateSinks.values.forEach { $0.finish() }
        stateSinks = [:]
        updateSinks = [:]
    }

    // MARK: Discovery

    /// One run at a time; a request during a run reruns once after it.
    private func refresh() {
        guard !closed else { return }
        guard running == nil else {
            rerun = true
            return
        }
        running = Task { await self.discover() }
    }

    private func discover() async {
        let outcome: Result<[SSHDiscoveredSession], SSHSessionFailure>
        do {
            let runner = try await makeRunner()
            let output = try await runner.run(discovery.command, input: discovery.input)
            outcome = .success(discovery.parse(output))
        } catch {
            outcome = .failure(SSHSessionFailure(error))
        }
        guard !closed, !Task.isCancelled else {
            running = nil
            return
        }
        switch outcome {
        case .success(let sessions):
            await catalog.record(sessions, for: hostID)
            seq += 1
            let state = SSHWorkspaceProjection(hostID: hostID.rawValue).state(sessions)
            let frame = SnapshotFrame(stream: stream, seq: seq, state: state, decided: [])
            set(.live(path: "ssh", caps: []))
            updateSinks.values.forEach { $0.yield(.snapshot(frame)) }
        case .failure(let failure):
            // What the host lists is unknown now: nothing stays attachable.
            await catalog.forget(hostID)
            set(.offline(reason: reasons.text(for: failure)))
        }
        // Cleared only now, so a refresh during the awaits above reruns
        // after this run instead of overlapping it.
        running = nil
        if rerun {
            rerun = false
            refresh()
        }
    }

    /// Subscribes to terminal endings before the first run, so none is missed.
    private func startListening() async {
        guard endings == nil, !closed else { return }
        let stream = await catalog.endings()
        guard endings == nil else { return }
        let host = hostID
        endings = Task { [weak self] in
            for await ended in stream where ended == host {
                await self?.refresh()
            }
        }
    }

    private func set(_ new: WorkspaceChannelState) {
        guard new != state else { return }
        state = new
        stateSinks.values.forEach { $0.yield(new) }
    }

    private func dropState(_ id: UUID) { stateSinks[id] = nil }
    private func dropUpdates(_ id: UUID) { updateSinks[id] = nil }
}
