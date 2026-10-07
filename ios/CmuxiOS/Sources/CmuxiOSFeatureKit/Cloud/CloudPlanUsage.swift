import Foundation

/// The team's usage in the current period (`CloudPlan.usage`).
public struct CloudPlanUsage: Hashable, Sendable {
    public var active: Int
    public var saved: Int
    public var vmHoursUsed: Double
    public var periodEnd: Date

    public init(active: Int = 0, saved: Int = 0, vmHoursUsed: Double = 0, periodEnd: Date = Date(timeIntervalSince1970: 0)) {
        self.active = active
        self.saved = saved
        self.vmHoursUsed = vmHoursUsed
        self.periodEnd = periodEnd
    }
}
