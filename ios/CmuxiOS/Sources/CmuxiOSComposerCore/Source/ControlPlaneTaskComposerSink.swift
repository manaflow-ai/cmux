public import CmuxiOSFeatureKit
public import CmuxiOSWorkspacesCore
import CmuxMobileWire
import Foundation

/// The real `TaskComposerSink` (c8-composer.md 4.1).
///
/// Hosts and workspaces come from C5's `WorkspaceSource` (one workspace
/// mirror in the app). Each paired Mac gets a channel on its `task:<host>`
/// stream (the Mac's task runner, mirrored by `HostDO`) feeding a
/// `TaskStreamMirror`: agents, models, efforts and task states. Channels
/// exist only while someone subscribes the catalog or a task stream, so a
/// hidden composer costs nothing. Dispatch is one `task.dispatch` op with
/// the intent key; nothing queues while the Mac is unreachable.
public actor ControlPlaneTaskComposerSink: TaskComposerSink {
    /// The cap a Mac advertises when it accepts dispatch.
    public static let dispatchCap = "task.dispatch"

    private let workspaces: any WorkspaceSource
    private let channels: any WorkspaceChannelFactory
    private var hosts: SourceSnapshot<[HostWorkspaces]>?
    private var sessions: [HostID: TaskHostSession] = [:]
    private var catalogSinks: [UUID: AsyncStream<SourceSnapshot<ComposerCatalog>>.Continuation] = [:]
    private var taskSinks: [UUID: (host: HostID, sink: AsyncStream<SourceSnapshot<[TaskRecord]>>.Continuation)] = [:]
    private var workspacePump: Task<Void, Never>?
    private var revision: UInt64 = 0

    /// `channels` opens a host's `task:` stream (for B1:
    /// `ControlPlaneWorkspaceChannelFactory(...).streaming("task")`).
    public init(workspaces: any WorkspaceSource, channels: any WorkspaceChannelFactory) {
        self.workspaces = workspaces
        self.channels = channels
    }

    // MARK: TaskComposerSink

    public func catalog() -> AsyncStream<SourceSnapshot<ComposerCatalog>> {
        let (stream, sink) = AsyncStream.makeStream(of: SourceSnapshot<ComposerCatalog>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        catalogSinks[id] = sink
        sink.onTermination = { [weak self] _ in Task { await self?.dropCatalogSink(id) } }
        sink.yield(catalogSnapshot)
        start()
        return stream
    }

    public func tasks(on host: HostID) -> AsyncStream<SourceSnapshot<[TaskRecord]>> {
        let (stream, sink) = AsyncStream.makeStream(of: SourceSnapshot<[TaskRecord]>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        taskSinks[id] = (host, sink)
        sink.onTermination = { [weak self] _ in Task { await self?.dropTaskSink(id) } }
        sink.yield(taskSnapshot(host))
        start()
        return stream
    }

    public func dispatch(_ draft: TaskDraft, key: IntentKey) async throws -> TaskReceipt {
        guard let session = sessions[draft.hostID], case .live = session.state else { throw FeatureSourceError.offline }
        guard session.acceptsDispatch else { throw FeatureSourceError.unsupported(Self.dispatchCap) }
        let encoder = TaskDispatchEncoder(draft: draft, key: key)
        do {
            return encoder.receipt(for: try await session.channel.submit(encoder.frame))
        } catch {
            // Not sent, or sent with the outcome unknown: the caller keeps the
            // key and a retry with it is deduped by the Mac's ledger.
            throw FeatureSourceError.offline
        }
    }

    // MARK: Lifecycle

    private var hasSubscribers: Bool { !catalogSinks.isEmpty || !taskSinks.isEmpty }

    private func start() {
        guard workspacePump == nil else { return }
        let workspaces = self.workspaces
        workspacePump = Task { [weak self] in
            for await snapshot in await workspaces.updates() {
                guard !Task.isCancelled else { return }
                await self?.hostsChanged(snapshot)
            }
        }
    }

    private func stopIfIdle() async {
        guard !hasSubscribers else { return }
        workspacePump?.cancel()
        workspacePump = nil
        hosts = nil
        let closing = sessions.values
        sessions.removeAll()
        for session in closing {
            session.pumps.forEach { $0.cancel() }
            await session.channel.close()
        }
    }

    private func dropCatalogSink(_ id: UUID) async {
        catalogSinks[id] = nil
        await stopIfIdle()
    }

    private func dropTaskSink(_ id: UUID) async {
        taskSinks[id] = nil
        await stopIfIdle()
    }

    // MARK: Hosts and sessions

    private func hostsChanged(_ snapshot: SourceSnapshot<[HostWorkspaces]>) async {
        hosts = snapshot
        let macs = snapshot.value.filter { $0.kind == .mac }
        let wanted = Set(macs.map(\.hostID))
        for (id, session) in sessions where !wanted.contains(id) {
            sessions[id] = nil
            session.pumps.forEach { $0.cancel() }
            await session.channel.close()
        }
        for host in macs where sessions[host.hostID] == nil {
            open(host)
        }
        publish()
    }

    private func open(_ host: HostWorkspaces) {
        let id = host.hostID
        let channel = channels.channel(for: WorkspaceHostDescriptor(id: id, name: host.hostName, kind: host.kind))
        var session = TaskHostSession(hostID: id, channel: channel)
        session.pumps.append(Task { [weak self] in
            for await state in await channel.states() {
                guard !Task.isCancelled else { return }
                await self?.stateChanged(id, state)
            }
        })
        session.pumps.append(Task { [weak self] in
            for await update in await channel.updates() {
                guard !Task.isCancelled else { return }
                await self?.received(id, update)
            }
        })
        sessions[id] = session
    }

    private func stateChanged(_ id: HostID, _ state: WorkspaceChannelState) {
        guard sessions[id] != nil, sessions[id]?.state != state else { return }
        sessions[id]?.state = state
        publish()
    }

    private func received(_ id: HostID, _ update: WorkspaceStreamUpdate) async {
        guard var session = sessions[id] else { return }
        let applied: TaskStreamMirror.Applied
        switch update {
        case .snapshot(let frame): applied = session.mirror.apply(snapshot: frame)
        case .event(let frame): applied = session.mirror.apply(event: frame)
        }
        sessions[id] = session
        switch applied {
        case .changed: publish()
        case .unchanged: break
        case .needsSnapshot: await session.channel.requestSnapshot()
        }
    }

    // MARK: Snapshots

    private var catalogSnapshot: SourceSnapshot<ComposerCatalog> {
        let macs = hosts?.value.filter { $0.kind == .mac } ?? []
        var agents: [HostID: [ComposerAgent]] = [:]
        var dispatch: Set<HostID> = []
        for (id, session) in sessions {
            if session.mirror.seq != nil { agents[id] = session.mirror.agents }
            if session.acceptsDispatch { dispatch.insert(id) }
        }
        for host in macs where agents[host.hostID] == nil { agents[host.hostID] = [] }
        let catalog = ComposerCatalog(hosts: macs, agents: [], agentsByHost: agents, dispatchHosts: dispatch)
        return SourceSnapshot(revision: revision, value: catalog, connection: hosts?.connection ?? .connecting)
    }

    private func taskSnapshot(_ host: HostID) -> SourceSnapshot<[TaskRecord]> {
        let session = sessions[host]
        return SourceSnapshot(revision: revision, value: session?.mirror.tasks ?? [],
                              connection: session?.connection ?? .connecting)
    }

    private func publish() {
        revision += 1
        let catalog = catalogSnapshot
        for sink in catalogSinks.values { sink.yield(catalog) }
        for entry in taskSinks.values { entry.sink.yield(taskSnapshot(entry.host)) }
    }
}
