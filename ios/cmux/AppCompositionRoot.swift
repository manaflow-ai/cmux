import CmuxMobileTransport
import cmuxFeature

/// Holds the de-singletonized graph the `cmuxApp` builds once at launch.
///
/// Owns the mobile runtime, the auth composition (coordinator + push
/// registration), the process-wide reachability monitor, and the shared push
/// coordinator. Everything below the app shell receives these by injection
/// instead of reaching for a singleton.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let reachability: any ReachabilityProviding
    let pushCoordinator: MobilePushCoordinator

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.pushCoordinator = MobilePushCoordinator(registration: auth.pushRegistration)
    }
}
