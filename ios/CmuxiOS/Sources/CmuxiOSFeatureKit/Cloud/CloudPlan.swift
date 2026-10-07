import Foundation

/// The team's Cloud plan, limits and usage (`cloud.plan.get`).
public struct CloudPlan: Hashable, Sendable {
    /// `none` when the team has no plan (create answers `cloud.plan.required`).
    public var planID: String
    /// The plan that lifts these limits, for "See plans"; nil when none.
    public var upgradePlan: String?
    public var limits: CloudPlanLimits
    public var usage: CloudPlanUsage

    public init(planID: String, upgradePlan: String? = nil, limits: CloudPlanLimits = CloudPlanLimits(),
                usage: CloudPlanUsage = CloudPlanUsage()) {
        self.planID = planID
        self.upgradePlan = upgradePlan
        self.limits = limits
        self.usage = usage
    }

    public var hasPlan: Bool { planID != "none" }
}
