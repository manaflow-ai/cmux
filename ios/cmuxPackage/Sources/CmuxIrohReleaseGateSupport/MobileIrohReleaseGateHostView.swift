#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileShellUI
import SwiftUI

struct MobileIrohReleaseGateHostView: View {
    @State private var store: CMUXMobileShellStore
    @State private var runner: MobileIrohReleaseGateRunner
    private let onboardingStore: MobileOnboardingStore
    private let signOutHook: MobileSignOutHook

    init(
        store: CMUXMobileShellStore,
        configuration: MobileIrohReleaseGateRunner.Configuration,
        onboardingStore: MobileOnboardingStore,
        signOutHook: MobileSignOutHook,
        settingsController: any CmxIrohSettingsControlling
    ) {
        _store = State(initialValue: store)
        _runner = State(initialValue: MobileIrohReleaseGateRunner(
            configuration: configuration,
            settingsController: settingsController
        ))
        self.onboardingStore = onboardingStore
        self.signOutHook = signOutHook
    }

    var body: some View {
        CMUXMobileAppView(
            store: store,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        .task {
            await runner.run(store: store)
        }
    }
}
#endif
