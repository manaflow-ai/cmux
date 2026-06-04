import CmuxMobileGhosttyEngine
import CmuxMobileTerminal
import CmuxMobileTransport
import cmuxFeature

/// Holds the de-singletonized graph the `cmuxApp` builds once at launch.
///
/// Owns the mobile runtime, the auth composition (coordinator + push
/// registration), the process-wide reachability monitor, the shared push
/// coordinator, and the Ghostty terminal engine provider. Everything below
/// the app shell receives these by injection instead of reaching for a
/// singleton.
@MainActor
final class AppCompositionRoot {
    let runtime: CMUXMobileRuntime
    let auth: MobileAuthComposition
    let reachability: any ReachabilityProviding
    let pushCoordinator: MobilePushCoordinator
    /// Lazily constructs the process's libghostty engine on first terminal
    /// mount (replaces `GhosttyRuntime.shared()`).
    let terminalEngine: GhosttyEngineProvider
    /// Accessory-bar configuration shared by the terminal toolbar and the
    /// shortcuts settings editor (replaces `TerminalAccessoryConfiguration.shared`).
    let terminalAccessoryConfiguration: TerminalAccessoryConfiguration

    init(
        runtime: CMUXMobileRuntime,
        auth: MobileAuthComposition,
        reachability: any ReachabilityProviding
    ) {
        self.runtime = runtime
        self.auth = auth
        self.reachability = reachability
        self.pushCoordinator = MobilePushCoordinator(registration: auth.pushRegistration)
        self.terminalEngine = GhosttyEngineProvider()
        self.terminalAccessoryConfiguration = TerminalAccessoryConfiguration()
    }
}
