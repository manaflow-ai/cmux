#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import SwiftUI
public import cmuxFeature

/// Debug-only wrapper that substitutes the isolated Iroh release gate while
/// preserving the production root scene and environment for ordinary launches.
@MainActor
public struct MobileIrohReleaseGateScene: View {
    private let root: CMUXMobileRootScene
    private let iroh: MobileIrohRuntimeComposition

    public init(
        root: CMUXMobileRootScene,
        iroh: MobileIrohRuntimeComposition
    ) {
        self.root = root
        self.iroh = iroh
    }

    @ViewBuilder
    public var body: some View {
        if let configuration = MobileIrohReleaseGateRunner.Configuration.current() {
            root.applyingRootEnvironment(
                to: MobileIrohReleaseGateHostView(
                    store: root.makeStore(),
                    configuration: configuration,
                    onboardingStore: root.onboardingStore,
                    signOutHook: root.signOutHook,
                    settingsController: iroh,
                    endpointIdentity: { await iroh.releaseGateEndpointIdentity() },
                    relayCredentialExpiry: {
                        await iroh.releaseGateRelayCredentialExpiry()
                    }
                )
            )
        } else {
            root
        }
    }
}
#endif
