import CmuxiOSAuth
import CmuxiOSFeatureKit
import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import Foundation

/// Builds onboarding models from the container: the first run (persisted,
/// resumable) and the Settings replay (in memory).
@MainActor
enum OnboardingComposition {
    static func firstRun(container: AppContainer, isSignedIn: Bool) -> OnboardingModel {
        var start: OnboardingStep?
        switch container.onboardingPolicy.decision {
        case .fresh(let step), .stored(let step): start = step
        case .skip: start = nil
        }
        return OnboardingModel(
            dependencies: dependencies(container: container, store: container.onboardingStore),
            context: OnboardingContext(isSignedIn: isSignedIn, mode: .firstRun),
            start: start
        )
    }

    static func replay(container: AppContainer) -> OnboardingModel {
        OnboardingModel(
            dependencies: dependencies(container: container, store: InMemoryProgressStore()),
            context: OnboardingContext(isSignedIn: true, mode: .replay)
        )
    }

    private static func dependencies(container: AppContainer, store: any OnboardingProgressPersisting) -> OnboardingDependencies {
        #if DEBUG
        let offersSampleScan = true
        #else
        let offersSampleScan = false
        #endif
        let clock = ContinuousClock()
        return OnboardingDependencies(
            devices: devices(container: container, clock: clock),
            hosts: AccountHostsStore { [weak container] in
                guard let container, case .signedIn(let account) = container.auth.state else { return nil }
                return container.featureSources(for: account).hosts
            },
            permissions: container.permissions,
            clock: clock,
            metrics: LogOnboardingMetrics(),
            store: store,
            signIn: { [weak container] in
                guard let container else { return UIViewControllerPlaceholder.make() }
                return SignInScreen.makeEmbedded(coordinator: container.auth.coordinator)
            },
            offersSampleScan: offersSampleScan
        )
    }

    /// The account registry once lane B6 registers a real one; until then
    /// the onboarding demo registry (one Mac discovered after a moment),
    /// because the shared mock already trusts two Macs.
    private static func devices(container: AppContainer, clock: ContinuousClock) -> any DeviceRegistry {
        if case .signedIn(let account) = container.auth.state {
            let sources = container.featureSources(for: account)
            if sources.resolved[.devices] == .real { return sources.devices }
        }
        return OnboardingDemoDevices.make(clock: clock)
    }
}
