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
    private let irx: MobileIrxRuntimeComposition
    private let settingsController: any CmxIrohSettingsControlling

    public init(
        root: CMUXMobileRootScene,
        irx: MobileIrxRuntimeComposition,
        settingsController: any CmxIrohSettingsControlling
    ) {
        self.root = root
        self.irx = irx
        self.settingsController = settingsController
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
                    settingsController: settingsController,
                    endpointIdentity: { await irx.releaseGateEndpointIdentity() },
                    relayCredentialExpiry: {
                        await irx.releaseGateRelayCredentialExpiry()
                    }
                )
            )
        } else {
            root
        }
    }
}
#endif
