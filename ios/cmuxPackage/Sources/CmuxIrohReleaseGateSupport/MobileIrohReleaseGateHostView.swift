#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileShellUI
import CmuxMobileTerminal
import Foundation
import SwiftUI

struct MobileIrohReleaseGateHostView: View {
    @State private var session: MobileShellUISession
    @State private var runner: MobileIrohReleaseGateRunner
    private let onboardingStore: MobileOnboardingStore
    private let signOutHook: MobileSignOutHook

    init(
        store: CMUXMobileShellStore,
        configuration: MobileIrohReleaseGateRunner.Configuration,
        onboardingStore: MobileOnboardingStore,
        signOutHook: MobileSignOutHook,
        terminalRuntimeOwner: GhosttyRuntimeOwner,
        settingsController: any CmxIrohSettingsControlling,
        endpointIdentity: @escaping @Sendable () async -> CmxIrohPeerIdentity?,
        relayCredentialExpiry: @escaping @Sendable () async -> Date?
    ) {
        _session = State(initialValue: MobileShellUISession(
            store: store,
            terminalRuntimeOwner: terminalRuntimeOwner
        ))
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
        CMUXMobileAppSessionView(
            session: session,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        .task {
            await runner.run(store: session.store)
        }
    }
}
#endif
