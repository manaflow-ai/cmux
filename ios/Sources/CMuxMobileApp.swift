import SwiftUI

@main
struct CMuxMobileApp: App {
    @StateObject private var connectionStore = CmxConnectionStore(
        launchTicketStore: CmxKeychainLaunchTicketStateStore()
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionStore)
                .onOpenURL { url in
                    connectionStore.handleOpenURL(url)
                }
        }
    }
}
