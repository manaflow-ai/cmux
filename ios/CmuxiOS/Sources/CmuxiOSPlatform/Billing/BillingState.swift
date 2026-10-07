import Foundation

/// The plans on offer and the account's current plan (the cloud billing
/// owner is the source of truth; the store mirrors it).
public struct BillingState: Hashable, Sendable {
    public var plans: [BillingPlan]
    public var currentPlanID: String?
    public var phase: BillingPhase

    public init(plans: [BillingPlan], currentPlanID: String?, phase: BillingPhase = .idle) {
        self.plans = plans
        self.currentPlanID = currentPlanID
        self.phase = phase
    }
}
