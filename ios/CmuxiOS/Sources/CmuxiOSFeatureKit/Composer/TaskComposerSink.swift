import Foundation

/// Seam for lane C8 (task composer). `catalog()` streams what the composer
/// can target (hosts, their workspaces, agents with models and efforts);
/// `dispatch` sends one task and returns the owner's receipt; `tasks(on:)`
/// streams the host's task records (receipt progress).
public protocol TaskComposerSink: Sendable {
    func catalog() async -> AsyncStream<SourceSnapshot<ComposerCatalog>>
    func dispatch(_ draft: TaskDraft, key: IntentKey) async throws -> TaskReceipt
    func tasks(on host: HostID) async -> AsyncStream<SourceSnapshot<[TaskRecord]>>
}
