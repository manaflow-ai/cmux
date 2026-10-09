import Foundation

/// Seam for the Hosts tab and lanes B4 (direct addresses) and C9 (SSH).
/// Lists every machine the phone can connect to: paired Macs (mirrored from
/// `DeviceRegistry`), SSH hosts and direct addresses. SSH and direct records
/// are synced per account through the control plane; secrets never leave
/// the device's Keychain.
public protocol HostsStore: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[HostRecord]>>
    func add(_ draft: HostDraft, key: IntentKey) async throws -> IntentReceipt
    func update(_ id: HostID, with draft: HostDraft, key: IntentKey) async throws -> IntentReceipt
    func remove(_ id: HostID, key: IntentKey) async throws -> IntentReceipt
}
