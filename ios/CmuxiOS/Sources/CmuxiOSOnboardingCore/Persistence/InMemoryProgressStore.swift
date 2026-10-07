import Foundation

/// Progress that lives only as long as the process (replay, forced runs).
@MainActor
public final class InMemoryProgressStore: OnboardingProgressPersisting {
    public private(set) var progress: OnboardingProgress?

    public init(progress: OnboardingProgress? = nil) {
        self.progress = progress
    }

    public func load() -> OnboardingProgress? { progress }
    public func save(_ progress: OnboardingProgress) { self.progress = progress }
    public func reset() { progress = nil }
}
