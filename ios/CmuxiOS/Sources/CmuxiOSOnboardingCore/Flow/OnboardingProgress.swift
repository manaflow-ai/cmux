import Foundation

/// The durable part of onboarding: where to resume and how each seen step
/// ended. Client view state of this install; never synced.
public struct OnboardingProgress: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var current: OnboardingStep
    public var outcomes: [OnboardingStep: StepOutcome]
    public var finished: Bool

    public init(
        current: OnboardingStep = .welcome, outcomes: [OnboardingStep: StepOutcome] = [:], finished: Bool = false
    ) {
        version = Self.currentVersion
        self.current = current
        self.outcomes = outcomes
        self.finished = finished
    }

    public static var fresh: OnboardingProgress { OnboardingProgress() }
}
