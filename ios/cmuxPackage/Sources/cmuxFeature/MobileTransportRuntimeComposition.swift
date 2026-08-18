import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileTransport
import Foundation

/// The iOS transport composition root.
///
/// This owner contains no endpoint, relay, VPN, or discovery state. The
/// Network.framework actor and the RPC session own connection lifecycle. The
/// composition object is intentionally small so there is one transport factory
/// and one place to evolve its policy.
@MainActor
public final class MobileTransportRuntimeComposition {
    public let transportFactory: CmxNetworkByteTransportFactory

    public init(
        apiBaseURL _: String = "",
        reachability _: any ReachabilityProviding,
        supportedKinds: [CmxAttachTransportKind] = [.tcp, .debugLoopback],
        discoveryCompatibilityPolicy _: MobileMacBuildCompatibilityPolicy? = nil,
        defaults _: UserDefaults = .standard,
        infoDictionary _: [String: Any]? = nil,
        bundleIdentifier _: String? = nil,
        diagnosticLog _: DiagnosticLog? = nil
    ) {
        transportFactory = CmxNetworkByteTransportFactory(
            supportedKinds: supportedKinds
        )
    }

    /// Compatibility lifecycle hooks. They deliberately do no network work.
    public func configure(
        auth _: AuthCoordinator,
        connectivityInvalidationBaseURL _: URL?
    ) {}

    public func prepareForConnection() async {}
    public func archiveDiagnostics() {}
    public func didEnterBackground() {}
    @discardableResult public func didBecomeActive() -> Bool { true }
}
