import Foundation

/// What the team's plan allows (`CloudPlan.limits`). The client shows these
/// and never computes a limit itself.
public struct CloudPlanLimits: Hashable, Sendable {
    public var maxActive: Int
    public var maxSaved: Int
    public var memoryOptionsMB: [Int]
    public var lockedMemoryOptionsMB: [Int]
    public var vmHoursIncluded: Double?

    public init(maxActive: Int = 0, maxSaved: Int = 0, memoryOptionsMB: [Int] = [],
                lockedMemoryOptionsMB: [Int] = [], vmHoursIncluded: Double? = nil) {
        self.maxActive = maxActive
        self.maxSaved = maxSaved
        self.memoryOptionsMB = memoryOptionsMB
        self.lockedMemoryOptionsMB = lockedMemoryOptionsMB
        self.vmHoursIncluded = vmHoursIncluded
    }
}
