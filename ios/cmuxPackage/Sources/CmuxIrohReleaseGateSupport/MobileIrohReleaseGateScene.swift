#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileShell
public import cmuxFeature

/// Installs the debug Iroh release probe on the native mobile root when its
/// launch environment requests a release-gate scenario.
@MainActor
public enum MobileIrohReleaseGateController {
    public static func configure(
        root: CMUXMobileRootViewController,
        iroh: MobileIrohRuntimeComposition
    ) -> CMUXMobileRootViewController {
        guard let configuration = MobileIrohReleaseGateRunner.Configuration.current() else {
            return root
        }
        let runner = MobileIrohReleaseGateRunner(
            configuration: configuration,
            settingsController: iroh,
            endpointIdentity: { await iroh.releaseGateEndpointIdentity() },
            relayCredentialExpiry: { await iroh.releaseGateRelayCredentialExpiry() }
        )
        root.setStoreCreationHandler { store in
            Task { await runner.run(store: store) }
        }
        return root
    }
}
#endif
