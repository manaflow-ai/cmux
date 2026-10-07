import Foundation

/// Lane C12's hook for the Cloud step: the app creates the first machine
/// through the account's Cloud seam (smallest size the plan allows).
public struct OnboardingCloudHook: Sendable {
    public var createFirstMachine: @Sendable () async -> OnboardingCloudOutcome

    public init(createFirstMachine: @escaping @Sendable () async -> OnboardingCloudOutcome) {
        self.createFirstMachine = createFirstMachine
    }
}
