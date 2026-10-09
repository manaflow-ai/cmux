import Foundation

/// The team's Cloud machines (lane C12). Owner: `CloudDO`, one per team.
/// The real source mirrors `cloud:<team>` and overlays pending intents;
/// refusals come back as `.refused` receipts whose reason is the owner's
/// error code (`cloud.quota.exceeded`, ...), which screens localize.
public protocol CloudMachineSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<CloudState>>
    /// Throws `FeatureSourceError.offline` while the owner is unreachable
    /// (nothing queues).
    func perform(_ intent: CloudIntent, key: IntentKey) async throws -> IntentReceipt
}
