public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
public import CmuxiOSWorkspacesCore
public import CmuxMobileWire
import Foundation

/// An SSH host's workspace stream (e3-workspaces.md section 6): each
/// discovery run becomes one snapshot of `workspace:<host>`. Discovery runs
/// when the list subscribes, on `requestSnapshot()` and when an attached
/// terminal of the host ends; never on a timer. Lifecycle operations use the
/// explicit owner adapter when one is supplied; discovery remains the only
/// source of attachable targets.
public actor SSHWorkspaceChannel: WorkspaceControlChannel {
    /// Makes the runner for one run (resolving the host chain and login
    /// fresh, so an edited host takes effect); throws `SSHSessionFailure`.
    public typealias RunnerFactory = @Sendable () async throws -> any SSHCommandRunning
    /// Builds the durable owner for this host. The factory is intentionally
    /// async because a fresh SSH runner must be opened only when a mutation is
    /// actually submitted.
    public typealias LifecycleFactory = @Sendable
        (_ hostID: HostID, _ runner: RunnerFactory) async throws -> any SSHTmuxLifecycleMutating

    private let hostID: HostID
    private let makeRunner: RunnerFactory
    private let catalog: SSHSessionCatalog
    private let reasons: SSHWorkspaceReasons
    private let makeLifecycle: LifecycleFactory?
    private var lifecycle: (any SSHTmuxLifecycleMutating)?
    private let discovery = SSHSessionDiscovery()
    private var state: WorkspaceChannelState = .connecting
    private var stateSinks: [UUID: AsyncStream<WorkspaceChannelState>.Continuation] = [:]
    private var updateSinks: [UUID: AsyncStream<WorkspaceStreamUpdate>.Continuation] = [:]
    private var seq: UInt64 = 0
    private var running: Task<Void, Never>?
    private var rerun = false
    private var endings: Task<Void, Never>?
    private var closed = false

    public init(hostID: HostID, catalog: SSHSessionCatalog, reasons: SSHWorkspaceReasons,
                makeRunner: @escaping RunnerFactory, makeLifecycle: LifecycleFactory? = nil) {
        self.hostID = hostID
        self.catalog = catalog
        self.reasons = reasons
        self.makeRunner = makeRunner
        self.makeLifecycle = makeLifecycle
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
        guard let makeLifecycle else {
            return .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: "proto.unsupported",
                                         message: "SSH lifecycle is unavailable", retryable: false, replayed: false))
        }
        guard let mutation = SSHTmuxLifecycleMutation(op: op.op, params: op.params) else {
            return .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: "proto.unsupported",
                                         message: "SSH operation is unsupported", retryable: false, replayed: false))
        }
        guard await catalogContainsCurrentTarget(mutation) else {
            return .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: "ssh.session_gone",
                                         message: "SSH target is no longer present", retryable: true, replayed: false))
        }
        do {
            if lifecycle == nil { lifecycle = try await makeLifecycle(hostID, makeRunner) }
            guard let lifecycle else { throw SSHTmuxLifecycleOwnerError.invalidRequest }
            let receipt = try await lifecycle.submit(mutation, idempotencyKey: op.idempotencyKey)
            return .applied(ResultFrame(tx: "ssh", idempotencyKey: receipt.idempotencyKey,
                                        value: receipt.value, revision: receipt.revision, replayed: receipt.replayed))
        } catch let error as SSHTmuxLifecycleOwnerError {
            let (code, retryable): (String, Bool) = switch error {
            case .invalidRequest: ("validation.invalid", false)
            case .noPendingRecord, .idempotencyConflict: ("idempotency.conflict", false)
            case .indeterminate: ("outcome.unknown", false)
            case .malformedRecord: ("state.corrupt", false)
            }
            return .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: code,
                                         message: "SSH lifecycle operation was refused", retryable: retryable, replayed: false))
        } catch {
            // A lost SSH response is deliberately surfaced as unknown. The
            // durable owner leaves its pending record in place, so retrying
            // the same key cannot issue a second command.
            return .rejected(RejectFrame(tx: "ssh", idempotencyKey: op.idempotencyKey, code: "outcome.unknown",
                                         message: "SSH lifecycle operation outcome is unknown", retryable: false, replayed: false))
        }
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

    /// Lifecycle commands may only target the exact object returned by the
    /// latest discovery. This prevents stale UI state or a pasted socket path
    /// from crossing the SSH command boundary.
    private func catalogContainsCurrentTarget(_ mutation: SSHTmuxLifecycleMutation) async -> Bool {
        switch mutation {
        case .createWindow(let epoch, let sessionID, _):
            return await catalog.containsTmuxSession(host: hostID, serverPID: epoch.serverPID,
                                                     serverStart: epoch.serverStart, sessionID: sessionID)
        case .renameWindow(let epoch, let windowID, _), .killWindow(let epoch, let windowID):
            return await catalog.containsTmuxWindow(host: hostID, serverPID: epoch.serverPID,
                                                    serverStart: epoch.serverStart, windowID: windowID)
        case .createScreen:
            // screen create has no existing object; its name is validated by
            // the mutation and the durable key protects the command.
            return true
        case .renameScreen(let session, _), .killScreen(let session):
            return await catalog.target(host: hostID, surfaceID: "ssh:screen:\(session)") != nil
        case .createCmuxTUI(let socket, _), .renameCmuxTUI(let socket, _, _), .killCmuxTUI(let socket, _):
            guard let target = await catalog.target(host: hostID, surfaceID: "ssh:cmux-tui:" + (SSHCmuxTUISocket(validatingPath: socket)?.session.rawValue ?? "")) else { return false }
            guard case .cmuxTUI(_, let discovered) = target else { return false }
            return discovered.path == socket
        }
    }
}
