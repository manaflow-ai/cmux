import Foundation

/// A `TaskComposerSink` over the sample Macs and agents. Dispatch to an
/// unreachable host or with an empty prompt is refused.
public final class MockTaskComposerSink: TaskComposerSink {
    public let hub: MockSnapshotHub<ComposerCatalog>

    public init(catalog: ComposerCatalog = ComposerCatalog(hosts: MockFixtures.hostWorkspaces(), agents: MockFixtures.agents)) {
        hub = MockSnapshotHub(catalog)
    }

    public func catalog() async -> AsyncStream<SourceSnapshot<ComposerCatalog>> {
        await hub.stream()
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
        guard catalog.value.agents.contains(where: { $0.id == draft.agentID }) else {
            return .refused(key: key, reason: "Unknown agent")
        }
        return .started(key: key, workspaceID: draft.workspaceID ?? "ws_" + key.rawValue.prefix(8))
    }
}
