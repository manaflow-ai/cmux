import CmuxiOSFeatureKit
import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import CmuxiOSPlatform

/// Lane E5: the keep-awake card's hook over C16's `KeepAwakeControl`
/// (`AppContainer.keepAwakeFactory`, filled by D1b; the mock until then),
/// only while the `keepAwake` flag is on.
@MainActor
struct KeepAwakeComposition {
    static func onboardingHook(container: AppContainer) -> OnboardingKeepAwakeHook? {
        guard container.flags.isEnabled(.keepAwake) else { return nil }
        let control = container.makeKeepAwakeControl()
        return OnboardingKeepAwakeHook(
            reports: {
                let updates = await control.updates()
                return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                    let task = Task {
                        for await snapshot in updates {
                            continuation.yield(snapshot.value.mapValues { KeepAwakeReport(isSupported: $0.isSupported, isEnabled: $0.isEnabled) })
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            set: { host, enabled in
                do {
                    switch try await control.set(host, enabled: enabled, key: IntentKey()) {
                    case .refused(_, let reason): return reason
                    case .committed: return nil
                    }
                } catch {
                    return KeepAwakeComposition.offline
                }
            })
    }

    nonisolated static var offline: String {
        String(localized: "onboarding.keepAwake.offline", defaultValue: "This Mac is offline. Try again when it is connected.", bundle: .module)
    }
}
