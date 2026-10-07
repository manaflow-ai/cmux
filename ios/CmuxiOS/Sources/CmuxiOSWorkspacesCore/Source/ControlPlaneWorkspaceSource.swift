public import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

/// The real `WorkspaceSource`: one control-plane channel per host from the
/// directory, a confirmed mirror and an intent log per host, merged into
/// one stream (c5-workspaces.md section 5).
///
/// Channels run only while someone subscribes; the last subscriber leaving
/// closes them and keeps the mirrors as stale state for the next screen.
public actor ControlPlaneWorkspaceSource: WorkspaceSource {
    private let directory: any WorkspaceHostDirectory
    private let channels: any WorkspaceChannelFactory
    private var sessions: [HostID: WorkspaceHostSession] = [:]
    private var order: [HostID] = []
    private var directoryLoaded = false
    private var directoryTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<SourceSnapshot<[HostWorkspaces]>>.Continuation] = [:]

    public init(directory: any WorkspaceHostDirectory, channels: any WorkspaceChannelFactory) {
        self.directory = directory
        self.channels = channels
    }

    // MARK: WorkspaceSource

    public func updates() -> AsyncStream<SourceSnapshot<[HostWorkspaces]>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<[HostWorkspaces]>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        continuation.yield(current)
        if subscribers.count == 1 { start() }
        return stream
    }

    public func perform(_ intent: WorkspaceIntent, key: IntentKey) async throws -> IntentReceipt {
        let hostID = try host(of: intent)
        guard let session = sessions[hostID], session.isLive, let channel = session.channel else {
            throw FeatureSourceError.offline
        }
        let frame = try WorkspaceOpEncoder(hostID: hostID).frame(for: intent, key: key)
        // A second perform with a key already in flight sends again (the owner
        // dedupes) but leaves the first call's log entry to the first call.
        let owns = sessions[hostID]?.log.entries.contains { $0.key == key } == false
        if owns {
            sessions[hostID]?.log.append(intent, key: key)
            publish()
        }
        let outcome: WorkspaceOpOutcome
        do {
            outcome = try await channel.submit(frame)
        } catch {
            // Not sent, or the socket closed mid-flight: the overlay goes; a
            // resend after reconnect carries the same key (B1 client).
            if owns {
                sessions[hostID]?.log.remove(key)
                publish()
            }
            throw FeatureSourceError.offline
        }
        switch outcome {
        case .applied(let result):
            if let seq = UInt64(result.revision) {
                let mirrorSeq = sessions[hostID]?.mirror.seq
                sessions[hostID]?.log.committed(key, at: seq, mirrorSeq: mirrorSeq)
            } else {
                sessions[hostID]?.log.remove(key)
            }
            publish()
            // The merged stream's revision (one counter across hosts), not
            // the host seq: screens compare it with `SourceSnapshot.revision`.
            return .committed(key: key, revision: revision)
        case .rejected(let reject):
            sessions[hostID]?.log.remove(key)
            publish()
            return .refused(key: key, reason: reject.message)
        }
    }

    /// The current merged value (tests and the first yield).
    public var current: SourceSnapshot<[HostWorkspaces]> {
        let hosts = order.compactMap { sessions[$0]?.value }
        return SourceSnapshot(revision: revision, value: hosts, connection: connection)
    }

    // MARK: Lifecycle

    private func start() {
        directoryTask?.cancel()
        let directory = self.directory
        directoryTask = Task { [weak self] in
            for await hosts in await directory.hosts() {
                await self?.apply(directory: hosts)
            }
        }
        for id in order { open(id) }
    }

    private func stop() {
        directoryTask?.cancel()
        directoryTask = nil
        for id in order { shut(id) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty { stop() }
    }

    private func open(_ id: HostID) {
        guard var session = sessions[id], session.channel == nil else { return }
        let channel = channels.channel(for: session.descriptor)
        session.generation += 1
        let generation = session.generation
        session.channel = channel
        session.state = .connecting
        session.resyncRequested = false
        session.tasks = [
            Task { [weak self] in
                for await state in await channel.states() {
                    await self?.apply(state: state, host: id, generation: generation)
                }
            },
            Task { [weak self] in
                for await update in await channel.updates() {
                    await self?.apply(update: update, host: id, generation: generation)
                }
            },
        ]
        sessions[id] = session
    }

    private func shut(_ id: HostID) {
        guard var session = sessions[id], let channel = session.channel else { return }
        session.tasks.forEach { $0.cancel() }
        session.tasks = []
        session.channel = nil
        session.state = .connecting
        // The mirror keeps its seq: a resumed stream's contiguous events
        // still apply, anything else is a gap and resyncs.
        sessions[id] = session
        Task { await channel.close() }
    }

    // MARK: Inputs

    func apply(directory hosts: [WorkspaceHostDescriptor]) {
        directoryLoaded = true
        let ids = hosts.map(\.id)
        for gone in order where !ids.contains(gone) {
            shut(gone)
            sessions[gone] = nil
        }
        for host in hosts {
            if sessions[host.id] == nil {
                sessions[host.id] = WorkspaceHostSession(descriptor: host)
                if !subscribers.isEmpty { open(host.id) }
            } else {
                sessions[host.id]?.descriptor = host
            }
        }
        order = ids
        publish()
    }

    func apply(state: WorkspaceChannelState, host id: HostID, generation: Int) {
        guard var session = sessions[id], session.generation == generation, session.channel != nil,
              session.state != state else { return }
        session.state = state
        if case .live = state {
            // A (re)connected socket gets a fresh chance to repair a gap whose
            // snapshot request may have been lost with the old connection.
            session.resyncRequested = false
            if session.mirror.needsSnapshot { requestSnapshot(&session) }
        }
        sessions[id] = session
        publish()
    }

    func apply(update: WorkspaceStreamUpdate, host id: HostID, generation: Int) {
        guard var session = sessions[id], session.generation == generation, session.channel != nil else { return }
        let stream = WorkspaceOpEncoder(hostID: id).stream
        switch update {
        case .snapshot(let frame):
            guard frame.stream == stream else { return }
            do {
                try session.mirror.apply(frame)
                session.log.settle(decided: frame.decided, snapshotSeq: frame.seq)
                session.resyncRequested = false
            } catch {
                session.mirror.invalidate()
                requestSnapshot(&session)
            }
        case .event(let frame):
            guard frame.stream == stream else { return }
            switch session.mirror.apply(frame) {
            case .applied:
                session.log.settle(through: frame.seq)
            case .gap:
                requestSnapshot(&session)
            case .duplicate, .awaitingSnapshot:
                return
            }
        }
        sessions[id] = session
        publish()
    }

    /// One snapshot request per gap; events are ignored until it arrives.
    private func requestSnapshot(_ session: inout WorkspaceHostSession) {
        guard !session.resyncRequested, let channel = session.channel else { return }
        session.resyncRequested = true
        Task { await channel.requestSnapshot() }
    }

    // MARK: Output

    private func host(of intent: WorkspaceIntent) throws -> HostID {
        switch intent {
        case .create(let hostID, _):
            guard sessions[hostID] != nil else { throw FeatureSourceError.notFound(hostID.rawValue) }
            return hostID
        case .rename(let id, _), .close(let id), .markRead(let id):
            // The confirmed mirror decides the owner, so a repeated close of a
            // row the overlay already hides still reaches its host (which
            // answers by key or with `workspace.not_found`).
            for hostID in order where sessions[hostID]?.mirror.summaries(hostID: hostID).contains(where: { $0.id == id }) == true {
                return hostID
            }
            throw FeatureSourceError.notFound(id)
        }
    }

    private var connection: SourceConnection {
        guard directoryLoaded else { return .connecting }
        let states = order.compactMap { sessions[$0]?.state }
        if states.isEmpty { return .live(path: nil) }
        for state in states { if case .live(let path, _) = state { return .live(path: path) } }
        if states.contains(.connecting) { return .connecting }
        return .offline(reason: nil)
    }

    private func publish() {
        revision += 1
        let snapshot = current
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }
}
