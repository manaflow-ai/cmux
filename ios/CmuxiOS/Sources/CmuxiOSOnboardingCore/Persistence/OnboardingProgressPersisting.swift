import Foundation

/// Where onboarding progress lives. The first run writes through to the
/// device; automation and replays use the in-memory store so they never
/// change the real install's progress.
@MainActor
public protocol OnboardingProgressPersisting: AnyObject {
    func load() -> OnboardingProgress?
    func save(_ progress: OnboardingProgress)
    func reset()
}
