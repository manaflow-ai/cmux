import SwiftUI

@main
struct CMuxMobileApp: App {
    @StateObject private var connectionStore = CmxConnectionStore(
        launchTicketStore: CmxKeychainLaunchTicketStateStore()
    )
    #if DEBUG
    @StateObject private var longHaulStatus = CmxUITestingLongHaulStatus()
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(connectionStore)
                #if DEBUG
                if CmxUITestingLongHaulDriver.mode() != nil {
                    CmxUITestingLongHaulHarness(store: connectionStore, status: longHaulStatus)
                }
                #endif
            }
            .onOpenURL { url in
                connectionStore.handleOpenURL(url)
            }
        }
    }
}
