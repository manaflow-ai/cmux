#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileShellUI
import Foundation
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
        settingsController: any CmxIrohSettingsControlling,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity?,
        relayCredentialExpiry: @escaping @Sendable () async -> Date?
    ) {
        _store = State(initialValue: store)
        _runner = State(initialValue: MobileIrohReleaseGateRunner(
            configuration: configuration,
            settingsController: settingsController,
            endpointIdentity: endpointIdentity,
            relayCredentialExpiry: relayCredentialExpiry
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
