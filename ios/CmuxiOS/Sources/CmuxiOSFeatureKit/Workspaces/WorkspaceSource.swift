import Foundation

/// Seam for lane C5 (workspaces). The owner is each host's workspace store,
/// mirrored through the control plane; one stream covers every host so the
/// switcher can show multiple Macs.
public protocol WorkspaceSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[HostWorkspaces]>>
    func perform(_ intent: WorkspaceIntent, key: IntentKey) async throws -> IntentReceipt
}
