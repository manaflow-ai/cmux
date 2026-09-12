import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellUI
import CmuxMobileTransport
import SwiftUI

extension CMUXMobileRootScene {
    @MainActor
    func makeMobileAppView() -> CMUXMobileAppView {
        let browserStreamStore = BrowserStreamStore()
        let simulatorStreamStore = MobileSimulatorStreamStore()
        #if os(iOS)
        return CMUXMobileAppView(
            store: makeStore(
                browserStreamEvents: browserStreamStore,
                simulatorStreamStore: simulatorStreamStore
            ),
            browserStreamStore: browserStreamStore,
            simulatorStreamStore: simulatorStreamStore,
            onboardingStore: onboardingStore,
            signOutHook: signOutHook
        )
        #else
        return CMUXMobileAppView(
            store: makeStore(
                browserStreamEvents: browserStreamStore,
                simulatorStreamStore: simulatorStreamStore
            ),
            browserStreamStore: browserStreamStore,
            simulatorStreamStore: simulatorStreamStore,
            signOutHook: signOutHook
        )
        #endif
    }

}
