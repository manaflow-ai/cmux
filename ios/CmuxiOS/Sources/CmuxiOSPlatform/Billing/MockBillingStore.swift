public import CmuxiOSFeatureKit

/// Two canned plans; purchase switches the current plan, restore keeps it.
public final class MockBillingStore: BillingStore {
    public let hub: MockSnapshotHub<BillingState>

    public init() {
        hub = MockSnapshotHub(BillingState(plans: [
            BillingPlan(id: "pro.monthly", name: "Pro", displayPrice: "$20.00 / month", summary: "Cloud VMs and priority relay"),
            BillingPlan(id: "pro.yearly", name: "Pro (Yearly)", displayPrice: "$200.00 / year", summary: "Two months free"),
        ], currentPlanID: nil))
    }

    public func updates() async -> AsyncStream<SourceSnapshot<BillingState>> {
        await hub.stream()
    }

    public func purchase(_ planID: String, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { state in
            guard state.plans.contains(where: { $0.id == planID }) else { throw MockRefusal("Unknown plan") }
            state.currentPlanID = planID
            state.phase = .idle
        }
    }

    public func restore(key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { state in state.phase = .idle }
    }
}
