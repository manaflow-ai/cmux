import Foundation

/// Seam for lanes B6 (pairing) and C11 (settings, devices). The owner is the
/// account's device registry (`UserDO` / `PairingDO`); trust keys live in
/// each device's Secure Enclave-backed identity.
public protocol DeviceRegistry: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<[DeviceRecord]>>
    /// Redeems a pairing ticket (QR or same-account discovery).
    func pair(_ ticket: PairingTicket, key: IntentKey) async throws -> IntentReceipt
    func revoke(_ deviceID: DeviceRecord.ID, key: IntentKey) async throws -> IntentReceipt
    func rename(_ deviceID: DeviceRecord.ID, to name: String, key: IntentKey) async throws -> IntentReceipt
}
