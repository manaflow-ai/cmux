import Foundation

/// What the Cloud tab renders: the team's machines (mirror plus pending
/// intents), unanswered creates, and the plan once read.
public struct CloudState: Hashable, Sendable {
    public var machines: [CloudMachine]
    public var creating: [CloudPendingCreate]
    public var plan: CloudPlan?
    /// False until the first machine list arrived (loading state).
    public var isLoaded: Bool

    public init(machines: [CloudMachine] = [], creating: [CloudPendingCreate] = [], plan: CloudPlan? = nil,
                isLoaded: Bool = false) {
        self.machines = machines
        self.creating = creating
        self.plan = plan
        self.isLoaded = isLoaded
    }

    public func machine(_ id: String) -> CloudMachine? { machines.first { $0.id == id } }
}
