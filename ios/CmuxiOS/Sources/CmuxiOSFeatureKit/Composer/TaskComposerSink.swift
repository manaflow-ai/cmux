import Foundation

/// Seam for lane C8 (task composer). `catalog()` streams what the composer
/// can target (hosts, their workspaces, agents with models and efforts);
/// `dispatch` sends one task and returns the owner's receipt.
public protocol TaskComposerSink: Sendable {
    func catalog() async -> AsyncStream<SourceSnapshot<ComposerCatalog>>
    func dispatch(_ draft: TaskDraft, key: IntentKey) async throws -> TaskReceipt
}
