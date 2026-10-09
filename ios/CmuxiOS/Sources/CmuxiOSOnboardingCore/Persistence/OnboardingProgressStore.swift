public import Foundation

/// Onboarding progress as JSON in an injected `UserDefaults` (tests pass a
/// suite). An unreadable or older-version value reads as no progress.
@MainActor
public final class OnboardingProgressStore: OnboardingProgressPersisting {
    public static let key = "dev.cmux.ios.next.onboarding.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> OnboardingProgress? {
        guard let data = defaults.data(forKey: Self.key),
              let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data),
              progress.version == OnboardingProgress.currentVersion else { return nil }
        return progress
    }

    public func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
