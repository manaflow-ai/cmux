/// A rejected device name, as an error for `Result`.
public struct DeviceNameError: Error, Hashable, Sendable {
    public var problem: DeviceNameProblem

    public init(problem: DeviceNameProblem) { self.problem = problem }
}
