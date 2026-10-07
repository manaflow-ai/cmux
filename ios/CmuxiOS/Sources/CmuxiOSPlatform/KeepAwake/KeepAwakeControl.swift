public import CmuxiOSFeatureKit

/// Keep Mac Awake per Mac (B5 owns the Mac's power assertion; the phone
/// mirrors it and sends intents). Offline refuses; nothing queues (U5).
public protocol KeepAwakeControl: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[HostID: KeepAwakeState]>>
    func set(_ host: HostID, enabled: Bool, key: IntentKey) async throws -> IntentReceipt
}
