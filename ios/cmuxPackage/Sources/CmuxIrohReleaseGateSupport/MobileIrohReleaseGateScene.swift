#if os(iOS) && DEBUG
import CmuxIrohTransport
import SwiftUI
package import cmuxFeature

/// Debug-only wrapper that substitutes the isolated Iroh release gate while
/// preserving the production root scene and environment for ordinary launches.
@MainActor
public struct MobileIrohReleaseGateScene: View {
    private let root: CMUXMobileRootScene
    private let settingsController: any CmxIrohSettingsControlling

    public init(
        root: CMUXMobileRootScene,
        settingsController: any CmxIrohSettingsControlling
    ) {
        self.root = root
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
                    settingsController: settingsController
                )
            )
        } else {
            root
        }
    }
}
#endif
