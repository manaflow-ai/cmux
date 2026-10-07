public import CmuxiOSFeatureKit
public import CmuxiOSPlatform
public import Observation

/// State behind the plans stub: offers, current plan, purchase and restore.
@MainActor
@Observable
public final class PlansModel {
    public private(set) var state = BillingState(plans: [], currentPlanID: nil)
    public private(set) var connection: SourceConnection = .connecting
    public private(set) var working = false
    public private(set) var lastError: String?
    @ObservationIgnored private let store: any BillingStore

    public init(store: any BillingStore) { self.store = store }

    public func observe() async {
        for await snapshot in await store.updates() {
            state = snapshot.value
            connection = snapshot.connection
        }
    }

    public func purchase(_ planID: String) async { await run { try await self.store.purchase(planID, key: IntentKey()) } }

    public func restore() async { await run { try await self.store.restore(key: IntentKey()) } }

    private func run(_ intent: @MainActor () async throws -> IntentReceipt) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            if case .refused(_, let reason) = try await intent() { lastError = reason } else { lastError = nil }
        } catch {
            lastError = PlatformText.plansUnavailable
        }
    }
}
