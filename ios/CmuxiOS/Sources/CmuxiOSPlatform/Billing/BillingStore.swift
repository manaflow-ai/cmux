public import CmuxiOSFeatureKit

/// StoreKit billing seam. The real store wraps StoreKit 2 and delivers each
/// verified transaction to the cloud billing owner (plans with the cloud
/// lead, C12); until then `MockBillingStore`.
public protocol BillingStore: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<BillingState>>
    func purchase(_ planID: String, key: IntentKey) async throws -> IntentReceipt
    func restore(key: IntentKey) async throws -> IntentReceipt
}
