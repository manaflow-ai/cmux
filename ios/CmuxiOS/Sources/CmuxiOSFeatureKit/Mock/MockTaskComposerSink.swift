import Foundation

/// A `TaskComposerSink` over the sample Macs and agents. Dispatch to an
/// unreachable host, with an empty prompt or to an unavailable agent is
/// refused; a started task appears in `tasks(on:)` as queued, then running.
public final class MockTaskComposerSink: TaskComposerSink {
    public let hub: MockSnapshotHub<ComposerCatalog>
    public let taskHub: MockSnapshotHub<[TaskRecord]>

    public init(catalog: ComposerCatalog = ComposerCatalog(hosts: MockFixtures.hostWorkspaces(), agents: MockFixtures.agents)) {
        hub = MockSnapshotHub(catalog)
        taskHub = MockSnapshotHub([])
    }

    public func catalog() async -> AsyncStream<SourceSnapshot<ComposerCatalog>> {
        await hub.stream()
    }

    public func tasks(on host: HostID) async -> AsyncStream<SourceSnapshot<[TaskRecord]>> {
        let all = await taskHub.stream()
        return AsyncStream { continuation in
            let pump = Task {
                for await snapshot in all {
                    continuation.yield(SourceSnapshot(revision: snapshot.revision,
                                                      value: snapshot.value.filter { $0.hostID == host },
                                                      connection: snapshot.connection))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public func dispatch(_ draft: TaskDraft, key: IntentKey) async throws -> TaskReceipt {
        let catalog = await hub.current
        guard catalog.connection.isLive else { throw FeatureSourceError.offline }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused(key: key, reason: "Empty prompt")
        }
        guard let host = catalog.value.hosts.first(where: { $0.hostID == draft.hostID }), host.isReachable else {
            return .refused(key: key, reason: "Host unreachable")
        }
        guard let agent = catalog.value.agents(on: draft.hostID).first(where: { $0.id == draft.agentID }), agent.isAvailable else {
            return .refused(key: key, reason: "Unknown agent")
        }
        let workspaceID = draft.workspaceID ?? "ws_" + key.rawValue.prefix(8)
        let taskID = "task_" + key.rawValue.prefix(8)
        let tabID = "tab_" + key.rawValue.prefix(8)
        let record = TaskRecord(id: taskID, hostID: draft.hostID, workspaceID: workspaceID, tabID: tabID,
                                agentID: agent.id, state: .queued, title: String(draft.prompt.prefix(60)), createdAt: Date())
        if !(await taskHub.current.value.contains { $0.id == taskID }) {
            try await taskHub.commit { $0.insert(record, at: 0) }
            await Task.yield()
            try await taskHub.commit { tasks in
                if let index = tasks.firstIndex(where: { $0.id == taskID }) { tasks[index].state = .running }
            }
        }
        return .started(key: key, workspaceID: workspaceID, taskID: taskID, tabID: tabID)
    }
}
