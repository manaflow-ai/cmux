public import CmuxiOSFeatureKit
import Foundation

/// The usage block: active and saved machines against the plan, VM hours.
public struct CloudUsageSummary: Hashable, Sendable {
    public var planID: String
    public var hasPlan: Bool
    public var active: Int
    public var maxActive: Int
    public var saved: Int
    public var maxSaved: Int
    public var vmHoursUsed: Double
    public var vmHoursIncluded: Double?
    public var periodEnd: Date

    public init(plan: CloudPlan) {
        planID = plan.planID
        hasPlan = plan.hasPlan
        active = plan.usage.active
        maxActive = plan.limits.maxActive
        saved = plan.usage.saved
        maxSaved = plan.limits.maxSaved
        vmHoursUsed = plan.usage.vmHoursUsed
        vmHoursIncluded = plan.limits.vmHoursIncluded
        periodEnd = plan.usage.periodEnd
    }

    /// 0...1 for the active-machines bar; 0 without a limit.
    public var activeFraction: Double {
        maxActive > 0 ? min(1, Double(active) / Double(maxActive)) : 0
    }

    /// Whether the plan has room for one more running machine.
    public var hasRoom: Bool { hasPlan && active < maxActive }
}
